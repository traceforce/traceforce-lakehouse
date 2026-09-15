# TraceForce lakehouse (AWS, early access)

Query your AI-agent activity logs and TraceForce metadata with plain SQL, or in plain
English from Claude Code. Storage, ingest and query compute all run in your AWS account and
region; no TraceForce-operated compute runs here.

TraceForce's collector already writes activity logs to your S3 bucket (the Storage
Provider in TraceForce Settings). This Terraform module adds, in the same account:

| Piece | What it is |
|---|---|
| S3 Tables bucket + `traceforce` namespace | Apache Iceberg tables, compacted and expired by S3 itself |
| `agent_events` | one row per log record / span from every agent, flattened from the raw objects |
| `devices`, `agent_accounts`, `agent_conversations`, findings, MCP inventory, ... (17 tables, see `docs/EXPORT_CONTRACT.md`) | daily mirrors of your TraceForce metadata (written by TraceForce as JSON snapshots into your bucket) |
| Athena workgroup `traceforce-lakehouse` + a results bucket | where the ingest runs and where you query; results expire after 7 days |
| Step Functions + EventBridge Scheduler | hourly: load the last few days of new objects; daily: refresh the mirrors |
| IAM | ingest role (reads your TraceForce prefix only, writes only to the results bucket and the Iceberg tables), scheduler role, and a read-only query policy (output) to attach to your engineers' identities |
| CloudWatch alarm | raised when a scheduled run fails; optional SNS notification |
| Glue federated catalog `s3tablescatalog` | the account-level object that lets Athena see S3 Tables (skip with `create_glue_integration = false` if you already have it) |

Compute is Athena only: no Lambda, no containers, no code to upgrade. Two data flows to be
clear about: the daily metadata mirrors are written into your bucket by TraceForce's storage
role under the Storage Provider grant you already gave it, and query results go wherever
your Claude Code session sends them (your LLM provider). Query result files themselves stay
in a bucket this module owns, which TraceForce cannot read.

## Deploy

This is a Terraform module. Your root configuration supplies the provider, the region (the
logs bucket's region) and the state backend; the module never chooses where your state lives.

1. In TraceForce Settings, copy the values block. A complete root configuration:

   ```hcl
   terraform {
     backend "s3" {
       bucket       = "acme-terraform-state"          # NOT the logs bucket (TraceForce can write there)
       key          = "traceforce-lakehouse/terraform.tfstate"
       region       = "us-east-1"
       use_lockfile = true                            # Terraform >= 1.10; use dynamodb_table on older versions
     }
   }

   provider "aws" {
     region = "us-east-1"                             # must be the logs bucket's region
   }

   module "traceforce_lakehouse" {
     source      = "github.com/traceforce/traceforce-lakehouse//terraform?ref=v0.2.0"
     logs_bucket = "acme-traceforce-logs"
     logs_prefix = "traceforce"                       # "" if TraceForce writes at the bucket root
     # only if they apply to your account:
     # logs_kms_key_arn        = "arn:aws:kms:..."   # bucket uses a customer-managed key
     # create_glue_integration = false                # account already has the s3tablescatalog catalog
     # alarm_sns_topic_arn     = "arn:aws:sns:..."   # notify when a scheduled run fails
   }

   output "query_policy_json" { value = module.traceforce_lakehouse.query_policy_json }
   ```

2. `terraform init && terraform apply`. If the provider region is not the bucket's region the
   plan fails with a message telling you which region to use. The applying principal needs
   the usual rights to create the resources above plus `glue:CreateCatalog` and
   `glue:PassConnection` for the account-level S3 Tables catalog (skip with
   `create_glue_integration = false` if it already exists).

3. The first ingest starts within the hour and loads the last three upload days. To load
   older day-partitioned objects, start the state machine once with
   `{"job":"ingest","lookback_days":400}` (`lookback_days` is a JSON number, 1 to 4000).
   Order matters: devices must be on TraceForce collector 1.0.42 or later first. Objects
   written by older collectors have no `dt=` folder in the key and are not read, and a
   lake with no eligible objects looks healthy: hourly runs succeed with zero rows and
   the alarm stays quiet. Check `max(upload_ts)` after the first day.

4. Attach `terraform output -raw query_policy_json` to the IAM users or roles your engineers
   use, copy `skill/traceforce-lakehouse/` into `.claude/skills/` (project or home), and ask
   questions in Claude Code.

Local state is fine for a first try on one laptop and wrong after that: no locking, and a lost
laptop leaves resources nobody can cleanly destroy.

## What you can ask

Open Claude Code in a folder with the skill installed and ask in plain English. Claude writes
the SQL from the schema reference in the skill.

**What the activity logs make possible** (TraceForce's console shows findings and inventory;
these need the full stream of prompts, tool calls and decisions, joined to who and where):

- **Investigate**: show me everything around finding X: the prompts before it, the tool calls after it, and what the agent did with the result.
- **Autonomy**: which tool calls ran without a human approving them, by person and tool, and what did they do?
- **Footprint**: which files, shell commands and external hosts did agents touch this week? Anything under `.ssh`, `.aws` or `.env`?
- **MCP usage**: of the MCP servers installed on our machines, which are actually being called, by whom, how often, and which are never used?
- **Blocked**: which prompts were blocked and which tool calls were rejected, per person and day? (denied actions never reach TraceForce's tables)
- **Cost**: what did each person and model cost this month, in tokens and dollars?

**Also available, from TraceForce's own data:**

- **Sensitive data**: who sent credentials or PII this week, what type, in which file or prompt?
- **Risky actions**: which tool calls wrote to or deleted something, and how was each approved?
- **Shadow AI**: which agents are installed on which devices, who owns them, who uses a personal account?

## What is and is not in the lake

- **Activity logs, redacted.** By default TraceForce's collector masks each matched sensitive
  value (an API key, an SSN) in the stored logs; the rest of the prompt, response and tool
  call is intact. An org can turn redaction off per policy, in which case the logs are
  verbatim. The lake contains exactly what is in your bucket.
- **Findings, not values.** The findings tables carry what was found (type, category), where
  (session, file, offsets, line), when, and how it was triaged. The matched value itself lives
  in a separate evidence object under `findings/…/evidence/`, referenced by the finding's
  storage pointer. The lake does **not** ingest evidence: putting verbatim secrets into a
  SQL-queryable table would undo the redaction, and Athena's result files would carry them
  too. Reviewers see evidence through the TraceForce console or API, which is authorized and
  audited per request.
- **File contents** are never in the logs; file findings resolve to the file's name, type and
  size, and the redacted copy stays under `findings/`.

## Inputs and outputs

| Input | Required | Default | Meaning |
|---|---|---|---|
| `logs_bucket` | yes | | the Storage Provider bucket TraceForce writes to |
| `logs_prefix` | yes (may be `""`) | `""` | the key prefix from the Storage Provider setup |
| `logs_kms_key_arn` | no | `null` | customer-managed KMS key of the logs bucket, if any |
| `create_glue_integration` | no | `true` | create the account-level `s3tablescatalog` catalog |
| `alarm_sns_topic_arn` | no | `null` | SNS topic notified when a scheduled run fails |

| Output | Meaning |
|---|---|
| `query_policy_json` | read-only IAM policy for people and Claude Code |
| `athena_workgroup`, `athena_catalog`, `agent_events_fqn` | where and how to query |
| `state_machine_arn` | the scheduled ingest / exports state machine |
| `exports_root` | where TraceForce's export job writes the daily snapshots |

## Query by hand

```sql
-- Athena console: data source AwsDataCatalog, catalog s3tablescatalog/traceforce-lakehouse, database traceforce
SELECT agent, count(*) rows, min(ts) first, max(ts) last FROM agent_events GROUP BY 1;
```

or `skill/traceforce-lakehouse/scripts/athena_query.sh "SELECT ..."`.

## How the ingest works

- The collector writes activity objects as
  `s3://<bucket>/<prefix>/conversations/<agent>/dt=<YYYYMMDD>/<serial>/<account>/<session>/<file>`,
  where `dt` is the UTC upload day. `raw_conversations` is a Glue table over that layout with
  one string column holding each object's whole OTLP-JSON document, and projected partitions
  for the four supported agents and the day.
- Every hour the state machine runs one Athena statement
  (`terraform/sql/ingest_agent_events.sql.tftpl`): it lists the last three day folders, unnests
  resource → scope → record, and INSERTs into `agent_events`. An object is loaded once: rows
  keep their source path and the statement anti-joins on it, so re-reading yesterday is
  harmless. Two runs never overlap (the state machine checks for a running execution).
- Why three days: the folders are days, so today alone would miss objects uploaded just
  before midnight; the extra day covers a few failed runs and device clocks a day off. Late
  uploads from offline laptops land in a fresh day folder and are picked up normally.
- Cost stays flat as history grows: each run reads only a few days of raw objects, plus the
  `source_object` column of `agent_events` for the anti-join (dictionary-encoded, well under
  a dollar a month at a year of data). For the largest tenant we have measured (about 2,700
  objects a day) the whole ingest is a few dollars a month.

## How the metadata mirrors work

TraceForce writes one full snapshot per table per day to
`<prefix>/_traceforce/lakehouse/exports/<table>/dt=YYYY-MM-DD/<HHMMSS>.jsonl.gz`, under the same
TraceForce role your Storage Provider bucket policy already trusts. Each run creates a new key;
the job never overwrites or deletes. The daily run MERGEs the newest file into the Iceberg table
and deletes rows that are no longer in it (except when the newest snapshot is empty; see the
contract). See `docs/EXPORT_CONTRACT.md`. Expire old snapshots with a lifecycle rule on that
prefix if you want; they are small.

TraceForce writes the snapshots around 04:00 UTC; the mirror runs at 06:00 UTC. A file that
lands later is merged the next day, or immediately if you start the state machine with
`{"job":"exports"}`. To run the ingest by hand use `{"job":"ingest"}` (or an empty input); it reads the last three days.

## When it breaks

- Any failed scheduled run raises the CloudWatch alarm `traceforce-lakehouse-runs-failed`;
  set `alarm_sns_topic_arn` to be notified. The cause is in the state machine's execution
  history (Step Functions console).
- If the ingest was down for more than two days, start the state machine once with
  `{"job":"ingest","lookback_days":<days since the outage began, plus 2>}`. Nothing is loaded
  twice.
- Freshness check from Claude Code or Athena: `SELECT max(ingested_at), max(upload_ts) FROM
  agent_events`. More than two hours behind the newest object in your bucket means the
  ingest is failing, the schedule is disabled, or the devices are still on a collector older
  than 1.0.42 (their objects are not read).
- One malformed object under `conversations/AGENT_IDENTITY_*/` cannot stop the ingest (it
  yields no rows), but a corrupt gzip can. To find it, run with credentials that can read
  the raw prefix (the ingest role or an admin):
  `SELECT r."$path" FROM traceforce_lakehouse_raw.raw_conversations r WHERE ... ` narrowing by
  agent folder and date, then move the object out of the prefix; the anti-join never touches
  loaded objects, so nothing else is affected.
- Rotating the logs bucket means re-applying with the new `logs_bucket`; the module does not
  detect a moved bucket by itself.

## Encryption notes

Athena cannot write to S3 Tables from a workgroup that enforces SSE-KMS, so query results
are written with SSE-S3 to the module's own results bucket and expire after 7 days. The S3
Tables bucket uses S3 Tables' managed SSE-S3 encryption. Set `logs_kms_key_arn` when the logs
bucket uses a customer-managed key so the ingest role can decrypt the logs. Athena error
messages can quote fragments of the row that failed; those end up in the state machine's
execution history and its CloudWatch log group.

## Upgrades and schema changes

Nothing in the lakehouse is a source of truth, so every table can be rebuilt:

- **A module version that changes a table's columns recreates that table** (the S3 Tables
  Terraform resource replaces on schema change). `agent_events` refills itself: the next
  ingest sees an empty table and reloads every raw object (minutes for a few hundred MB).
  The metadata mirrors refill on the next daily run, or immediately if you start the state
  machine with `{"job":"exports"}`. Expect a short gap, not data loss. The schedule keeps firing
  during the apply, so expect one failed execution (and one alarm) in that window, or disable
  the `traceforce-lakehouse-ingest` schedule for the duration.
- **TraceForce adding a column to a source table** is invisible until a module version
  exposes it; nothing breaks.
- **TraceForce removing or retyping a column** would show up as NULLs. The export job
  validates every contract column before writing and alerts TraceForce instead.
- **A new agent attribute** lands in `attrs_json` immediately; a typed column follows in a
  module version.

## What is not here yet

- GCP and Azure (same shape planned: BigQuery/Iceberg and Fabric/Synapse respectively).
- ChatGPT activity (different capture format).
- Partitioning of `agent_events` (unpartitioned; S3 Tables compaction keeps scans cheap at POC scale).

## Licence

Apache License 2.0; see `LICENSE`.
