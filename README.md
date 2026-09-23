# TraceForce lakehouse

Query your AI-agent activity logs and TraceForce metadata with SQL, or in plain English from
Claude Code. Everything runs in your own cloud — the tables, the hourly load and the queries:
**Athena over Iceberg in AWS (S3)**, or **BigQuery over Iceberg in GCP (GCS)**. Your lakehouse
is set up on one of them; compute is serverless either way, so there are no servers to run and
nothing to upgrade. The easiest way to get the exact `main.tf` for your cloud is the Lakehouse
tile in TraceForce Settings.

Two things to know about data flow. The daily metadata snapshots are written into your bucket
by TraceForce's storage role under the grant you already gave it. Query results stay in a
bucket this module owns, which TraceForce cannot read.

## Before you start

- TraceForce Settings has an S3 or GCS Storage Provider configured: the bucket and prefix that
  TraceForce writes to. You will need both values.
- Terraform 1.5 or later.
- **AWS:** a principal that can create S3 Tables, Glue, Athena, Step Functions and IAM resources
  in that account; deploy in the bucket's region.
- **GCP:** the gcloud CLI signed in (`gcloud auth login` + `gcloud auth application-default
  login`) on the project that owns the bucket, as an identity that can create BigQuery
  datasets/connections/transfers and a service account, set IAM, and enable the BigQuery APIs —
  in practice **project Owner**.

## Deploy — AWS (Athena)

1. Create a root configuration. Keep the state in your own state bucket, never the logs bucket.

   ```hcl
   terraform {
     required_version = ">= 1.5"
     backend "s3" {
       bucket       = "acme-terraform-state"
       key          = "traceforce-lakehouse/terraform.tfstate"
       region       = "us-east-1"
     }
   }

   provider "aws" {
     region = "us-east-1" # the logs bucket's region
   }

   module "traceforce_lakehouse" {
     source      = "github.com/traceforce/traceforce-lakehouse//terraform/aws?ref=1.1.0"
     logs_bucket = "acme-traceforce-logs"
     logs_prefix = "traceforce" # "" if TraceForce writes at the bucket root

     # logs_kms_key_arn        = "arn:aws:kms:..." # bucket encrypted with a customer-managed key
     # create_glue_integration = false             # apply says the Glue catalog s3tablescatalog already exists
     # alarm_sns_topic_arn     = "arn:aws:sns:..." # get notified when a scheduled run fails
     # query_trusted_principals = ["arn:aws:iam::OTHER_ACCOUNT_ID:root"] # a separate team (no access to this account) queries via an assumed role
   }

   output "query_policy_json" { value = module.traceforce_lakehouse.query_policy_json }
   ```

2. `terraform init && terraform apply`. If the bucket uses a customer-managed KMS key, set
   `logs_kms_key_arn` now; without it the hourly load fails with Access Denied.

3. Attach `terraform output -raw query_policy_json` to the IAM users or roles that will query.

   If a separate team **without access to this account** will query, instead set
   `query_trusted_principals` to their principal ARN(s) and hand them
   `terraform output -raw query_role_arn`; they assume that read-only role from their own
   AWS identity (a `role_arn` profile in `~/.aws/config`).

4. Install the skill in your coding agent. Claude Code:

   ```
   /plugin marketplace add traceforce/traceforce-lakehouse
   /plugin install traceforce-lakehouse@traceforce
   ```

   Any other agent (Cursor, Copilot, Codex): see [`AGENTS.md`](AGENTS.md). Then ask questions.

The first load runs within the hour and covers the last three days. To load older data, start
the state machine `traceforce-lakehouse-ingest` once with `{"job":"ingest","lookback_days":400}`.

## Deploy — GCP (BigQuery)

1. Create a root configuration, keeping state in your own GCS bucket, never the logs bucket.

   ```hcl
   terraform {
     required_version = ">= 1.5"
     backend "gcs" {
       bucket = "acme-terraform-state"
       prefix = "traceforce-lakehouse"
     }
   }

   provider "google" {
     project = "acme-prod-482913" # the project that owns the bucket and runs BigQuery
   }

   module "traceforce_lakehouse" {
     source      = "github.com/traceforce/traceforce-lakehouse//terraform/gcp?ref=1.1.0"
     logs_bucket = "acme-traceforce-logs"
     logs_prefix = "traceforce" # "" if TraceForce writes at the bucket root

     # query_members = ["group:security@acme.com"] # a separate team gets read-only query access (they also need roles/bigquery.jobUser in their own project)
   }
   ```

   The dataset location is derived from the logs bucket — you do not set it.

2. `terraform init && terraform apply`.

3. Install the skill (Claude Code: the two `/plugin` commands above; other agents: see
   [`AGENTS.md`](AGENTS.md)). Set the lakehouse's project as your gcloud default
   (`gcloud config set project <id>`), then ask questions. Tables live in the
   `traceforce_lakehouse` dataset.

   The first load runs within the hour; to backfill older history, raise `lookback_days` and
   re-apply.

## Ask questions

- Show me everything around finding X: the prompts before it, the tool calls after it, and what the agent did with the result.
- Which tool calls ran without a human approving them, by person and tool?
- Of the MCP servers installed on our machines, which are actually called, by whom, and which never?
- Which prompts were blocked and which tool calls were rejected, per person and day?
- What did each person and model cost this month, in tokens and dollars?
- Who sent credentials or PII this week, what type, in which file or prompt?

By hand:

- **AWS:** the Athena console (data source `AwsDataCatalog`, catalog
  `s3tablescatalog/traceforce-lakehouse`, database `traceforce`) or
  `skills/traceforce-lakehouse/scripts/athena_query.sh "SELECT ..."`.
- **GCP:** the BigQuery console (dataset `traceforce_lakehouse`) or
  `skills/traceforce-lakehouse/scripts/bq_query.sh "SELECT ..."`.

```sql
SELECT agent, count(*) AS events, max(ts) AS latest FROM agent_events GROUP BY 1;
-- on GCP, qualify tables with the dataset: FROM traceforce_lakehouse.agent_events
```

## What is in the lake

- `agent_events`: one row per log record or span from every agent (Claude Code, Claude
  (claude.ai), Cursor, GitHub Copilot), loaded hourly.
- 17 metadata tables mirrored daily from TraceForce: devices, accounts, installs,
  conversations, findings, MCP inventory and catalog. Columns and joins are documented in
  `skills/traceforce-lakehouse/reference/`.
- Logs are stored exactly as TraceForce writes them, with sensitive values redacted according
  to your policy. Finding evidence (the matched value itself) is never loaded; review it in
  the TraceForce console.

## Is it working

- Freshness: `SELECT max(ingested_at), max(upload_ts) FROM agent_events`. More than two hours
  behind the newest object in your bucket means a run is failing or the schedule is disabled;
  if neither, contact TraceForce.
- **AWS:** the CloudWatch alarm `traceforce-lakehouse-runs-failed` raises on any failed
  scheduled run; set `alarm_sns_topic_arn` to be notified. The cause is in the Step Functions
  execution history. After an outage, start the state machine once with
  `{"job":"ingest","lookback_days":<days since it began, plus 2>}`. Nothing is loaded twice.
- **GCP:** failed loads show in the BigQuery Data Transfer console — the two scheduled queries
  that ingest `agent_events` and mirror the metadata tables. The metadata mirror is a MERGE, so
  re-running it loads nothing twice. To catch up `agent_events` after an outage, raise
  `lookback_days` and re-apply.

## More

- `docs/EXPORT_CONTRACT.md`: the snapshot format TraceForce writes into your bucket.
- Licence: Apache 2.0, see `LICENSE`.
