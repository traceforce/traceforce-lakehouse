# TraceForce lakehouse (AWS)

Query your AI-agent activity logs and TraceForce metadata with SQL in Athena, or in plain
English from Claude Code. Everything runs in your AWS account and region: the tables, the
hourly load and the queries. Compute is Athena only, so there are no servers to run and
nothing to upgrade.

Two things to know about data flow. The daily metadata snapshots are written into your bucket
by TraceForce's storage role under the grant you already gave it. Query results stay in a
bucket this module owns, which TraceForce cannot read.

## Before you start

- TraceForce Settings has an S3 Storage Provider configured: the bucket and prefix that
  TraceForce writes to. You will need both values.
- Terraform 1.5 or later, and an AWS principal that can create S3 Tables, Glue, Athena, Step
  Functions and IAM resources in that account.
- Deploy in the bucket's region.

## Deploy

1. Create a root configuration. Keep the state in your own state bucket, never the logs bucket.

   ```hcl
   terraform {
     backend "s3" {
       bucket       = "acme-terraform-state"
       key          = "traceforce-lakehouse/terraform.tfstate"
       region       = "us-east-1"
       use_lockfile = true
     }
   }

   provider "aws" {
     region = "us-east-1" # the logs bucket's region
   }

   module "traceforce_lakehouse" {
     source      = "github.com/traceforce/traceforce-lakehouse//terraform?ref=1.0.0"
     logs_bucket = "acme-traceforce-logs"
     logs_prefix = "traceforce" # "" if TraceForce writes at the bucket root

     # logs_kms_key_arn        = "arn:aws:kms:..." # bucket encrypted with a customer-managed key
     # create_glue_integration = false             # apply says the Glue catalog s3tablescatalog already exists
     # alarm_sns_topic_arn     = "arn:aws:sns:..." # get notified when a scheduled run fails
   }

   output "query_policy_json" { value = module.traceforce_lakehouse.query_policy_json }
   ```

2. `terraform init && terraform apply`. If the bucket uses a customer-managed KMS key, set
   `logs_kms_key_arn` now; without it the hourly load fails with Access Denied.

3. Attach `terraform output -raw query_policy_json` to the IAM users or roles that will query.

4. Copy `skill/traceforce-lakehouse/` into `.claude/skills/` (project or home) and ask
   questions in Claude Code.

The first load runs within the hour and covers the last three days. To load older data, start
the state machine `traceforce-lakehouse-ingest` once with `{"job":"ingest","lookback_days":400}`.

## Ask questions

- Show me everything around finding X: the prompts before it, the tool calls after it, and what the agent did with the result.
- Which tool calls ran without a human approving them, by person and tool?
- Of the MCP servers installed on our machines, which are actually called, by whom, and which never?
- Which prompts were blocked and which tool calls were rejected, per person and day?
- What did each person and model cost this month, in tokens and dollars?
- Who sent credentials or PII this week, what type, in which file or prompt?

By hand, in the Athena console (data source `AwsDataCatalog`, catalog
`s3tablescatalog/traceforce-lakehouse`, database `traceforce`) or with
`skill/traceforce-lakehouse/scripts/athena_query.sh "SELECT ..."`:

```sql
SELECT agent, count(*) AS events, max(ts) AS latest FROM agent_events GROUP BY 1;
```

## What is in the lake

- `agent_events`: one row per log record or span from every agent (Claude Code, Cursor,
  Claude desktop and Cowork, GitHub Copilot), loaded hourly.
- 17 metadata tables mirrored daily from TraceForce: devices, accounts, installs,
  conversations, findings, MCP inventory and catalog. Columns and joins are documented in
  `skill/traceforce-lakehouse/reference/`.
- Logs are stored exactly as TraceForce writes them, with sensitive values redacted according
  to your policy. Finding evidence (the matched value itself) is never loaded; review it in
  the TraceForce console.

## Is it working

- Freshness: `SELECT max(ingested_at), max(upload_ts) FROM agent_events`. More than two hours
  behind the newest object in your bucket means a run is failing or the schedule is disabled;
  if neither, contact TraceForce.
- The CloudWatch alarm `traceforce-lakehouse-runs-failed` raises on any failed scheduled run;
  set `alarm_sns_topic_arn` to be notified. The cause is in the Step Functions execution history.
- After an outage, start the state machine once with
  `{"job":"ingest","lookback_days":<days since it began, plus 2>}`. Nothing is loaded twice.

## More

- `CHANGELOG.md`: what each version changes, including any table that is rebuilt on upgrade.
- `docs/EXPORT_CONTRACT.md`: the snapshot format TraceForce writes into your bucket.
- Licence: Apache 2.0, see `LICENSE`.
