# TraceForce lakehouse

Query your AI-agent activity logs with SQL, or in plain English from Claude Code — on AWS and
GCP, also query TraceForce metadata (findings, catalogs, and more) the same way. Everything
runs in your own cloud — the tables, the hourly load and the queries: **Athena over Iceberg in
AWS (S3)**, **BigQuery over Iceberg in GCP (GCS)**, or **Snowflake over Iceberg in Azure (Blob
Storage)** *(early access — activity logs only for now; TraceForce's metadata export doesn't
support Azure yet)*. Your lakehouse is set up on one of them; compute is serverless either way,
so there are no servers to run and nothing to upgrade. The easiest way to get the exact
`main.tf` for your cloud is the Lakehouse tile in TraceForce Settings.

Azure is the one exception to "serverless either way, no separate account needed": it runs on
Snowflake, so unlike Athena/BigQuery (native to the same AWS/GCP account as your logs) you need
an existing Snowflake account and warehouse credits of your own.

Two things to know about data flow. The daily metadata snapshots are written into your bucket
by TraceForce's storage role under the grant you already gave it. Query results stay in a
bucket this module owns, which TraceForce cannot read.

## Before you start

- TraceForce Settings has an S3, GCS, or Azure Blob Storage Provider configured: the
  bucket/container and prefix that TraceForce writes to. You will need both values.
- Terraform 1.5 or later.
- **AWS:** a principal that can create S3 Tables, Glue, Athena, Step Functions and IAM resources
  in that account; deploy in the bucket's region.
- **GCP:** the gcloud CLI signed in (`gcloud auth login` + `gcloud auth application-default
  login`) on the project that owns the bucket, as an identity that can create BigQuery
  datasets/connections/transfers and a service account, set IAM, and enable the BigQuery APIs —
  in practice **project Owner**.
- **Azure** *(early access)*: an existing Snowflake account on Azure, in the logs storage
  account's region (anywhere else pays cross-region egress on every load and query), with a
  key-pair user that can create databases, warehouses and Tasks — in practice `ACCOUNTADMIN`.
  Deploying reads `SNOWFLAKE_PRIVATE_KEY` from the environment; the organization, account and
  user are plain provider arguments in the snippet. The Azure CLI signed in (`az login`) as an
  identity that can create a storage account and role assignments in the logs resource group —
  **Owner**, or **User Access Administrator** + **Storage Account Contributor** on that group
  (the module creates its own storage account there for the Iceberg data). The subscription and
  tenant IDs are provider arguments too (`az account show --query "{id:id,tenantId:tenantId}"`).
  The first deployment against a Snowflake account/tenant pair needs a Microsoft Entra admin to
  grant admin consent (step 3 below); subscription roles like Owner don't include that. With
  `use_azuread_auth`, the state storage account also needs `Storage Blob Data Contributor`.

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
     source      = "github.com/traceforce/traceforce-lakehouse//terraform/aws?ref=1.3.0"
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

The first load runs within the hour and covers the last few days.

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
     source      = "github.com/traceforce/traceforce-lakehouse//terraform/gcp?ref=1.3.0"
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

   The first load runs within the hour and covers the last few days.

## Deploy — Azure (Snowflake) *(early access)*

1. Create a root configuration. Keep the state in your own state storage account, never the
   logs storage account.

   ```hcl
   terraform {
     required_version = ">= 1.5"
     backend "azurerm" {
       subscription_id      = "00000000-0000-0000-0000-000000000000" # az account show --query id -o tsv
       tenant_id            = "00000000-0000-0000-0000-000000000000" # az account show --query tenantId -o tsv
       resource_group_name  = "acme-terraform-rg"
       storage_account_name = "acmetfstate"
       container_name       = "tfstate"
       key                  = "traceforce-lakehouse/terraform.tfstate"
       use_azuread_auth     = true
     }
     required_providers {
       azurerm = {
         source  = "hashicorp/azurerm"
         version = "~> 4.0"
       }
       azuread = {
         source  = "hashicorp/azuread"
         version = "~> 3.0"
       }
       snowflake = {
         source  = "snowflakedb/snowflake"
         version = "~> 2.0"
       }
     }
   }

   provider "azurerm" {
     subscription_id = "00000000-0000-0000-0000-000000000000" # az account show --query id -o tsv
     tenant_id       = "00000000-0000-0000-0000-000000000000" # az account show --query tenantId -o tsv
     features {}
   }

   # tenant_id pins this to the same directory as azurerm, rather than whichever tenant the
   # Azure CLI's current context happens to default to.
   provider "azuread" {
     tenant_id = "00000000-0000-0000-0000-000000000000" # az account show --query tenantId -o tsv
   }

   provider "snowflake" {
     organization_name = "acmeorg"        # Snowsight account selector, top-left
     account_name      = "acmeaccount"    # the account name, not the account locator
     user              = "acmedeployuser" # the Snowflake user Terraform authenticates as
     authenticator     = "SNOWFLAKE_JWT"  # key-pair auth; this module always uses it, not a choice

     # private_key is the one real secret here -- deliberately not set above like the rest:
     # reads from SNOWFLAKE_PRIVATE_KEY in the environment, never hardcoded in this file.

     # preview_features_enabled is required: several resource types this module needs (external
     # tables, Iceberg tables, email notifications, alerts) are still preview-status in the
     # provider.
     preview_features_enabled = [
       "snowflake_external_table_resource",
       "snowflake_iceberg_table_resource",
       "snowflake_email_notification_integration_resource",
       "snowflake_alert_resource",
     ]
   }

   module "traceforce_lakehouse" {
     source = "github.com/traceforce/traceforce-lakehouse//terraform/azure?ref=1.3.0"

     # Must be globally unique across all of Azure (storage account names share one namespace
     # account-wide) and stable for the life of the deployment: changing it later destroys and
     # recreates the storage account, deleting the Iceberg table files.
     iceberg_storage_account_name = "acmetraceforcelakehouse"

     logs_storage_account_name = "acmetraceforcelogs"
     logs_resource_group_name  = "acme-logs-rg"
     logs_container_name       = "logs"
     logs_prefix               = "traceforce" # "" if TraceForce writes at the container root

     # warehouse_size             = "SMALL"       # default XSMALL; bump if ad-hoc queries feel slow
     # alarm_notification_email   = "jdoe@acme.com" # a verified Snowflake user's email, not a team address -- get notified when a scheduled Task fails
     # reader_users               = ["JDOE"]       # existing Snowflake usernames granted read-only access
     # credit_notification_users  = ["JDOE"]       # existing Snowflake usernames emailed as credit usage climbs (the monitor itself never suspends the warehouse)
   }

   output "azure_consent_url" { value = module.traceforce_lakehouse.azure_consent_url }
   output "reader_role_name" { value = module.traceforce_lakehouse.reader_role_name }
   ```

2. `terraform init && terraform apply`. The very first time this module deploys against a given
   Snowflake account + Azure tenant pair, expect this apply to get partway through and then stop
   on an error naming a consent URL: Snowflake creates its own Azure AD service principal to
   read/write your storage, and it can't be granted a role assignment until an Azure AD admin
   has consented to it. That's expected, not a failure — a redeploy later (even a full
   `destroy` + `apply`) won't hit it again, since consent is tied to the Snowflake
   account/tenant pair, not to this particular deployment.

3. Open the consent URL the error printed (or `terraform output -raw azure_consent_url`) and
   grant admin consent, then run `terraform apply` again. It completes the rest of the module
   this time — role assignments, the Iceberg tables, and the scheduled ingest/export Tasks.

4. Grant query access. Use a dedicated read-only user for this, not the user you deployed
   with (in practice `ACCOUNTADMIN`) — its key already exists and is the path of least
   resistance, but handing a coding agent a key that broad is unnecessary exposure when the
   reader role is the only access querying actually needs. Create one with key-pair auth, the
   same way as step 1's own deploy user:

   ```sql
   CREATE USER traceforce_query TYPE = SERVICE RSA_PUBLIC_KEY = '<public key>';
   GRANT ROLE "traceforce_lakehouse_reader" TO USER traceforce_query;
   ```

   Or list it in `reader_users` in step 1 (as `TRACEFORCE_QUERY`) and skip the `GRANT ROLE`
   here. Either way, step 5's `SNOWFLAKE_USER`/`SNOWFLAKE_PRIVATE_KEY` should be this user's,
   not the deploy user's.

5. Install the skill in your coding agent. Claude Code:

   ```
   /plugin marketplace add traceforce/traceforce-lakehouse
   /plugin install traceforce-lakehouse@traceforce
   ```

   Any other agent (Cursor, Copilot, Codex): see [`AGENTS.md`](AGENTS.md). Querying needs
   python3 with `snowflake-connector-python` and, as the step 4 user, either the five
   `SNOWFLAKE_*` environment variables (listed in `snowflake_query.sh`) or a `connections.toml`
   connection. Then ask questions.

The first load runs within the hour and covers the last few days.

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
- **Azure:** Snowsight (database `traceforce_lakehouse`, schema `traceforce`, warehouse
  `traceforce_lakehouse`) with the reader role from step 4 above active (`USE ROLE`) — the
  reader only has `USAGE` on that specific warehouse, so a query fails without it selected.

```sql
SELECT agent, count(*) AS events, max(ts) AS latest FROM agent_events GROUP BY 1;
-- on GCP, qualify tables with the dataset: FROM traceforce_lakehouse.agent_events
-- on Azure/Snowflake, quote every identifier -- table and column names are case-preserved
-- lowercase, and this snippet's bare, unquoted names would otherwise fold to uppercase and
-- not be found: SELECT "agent", count(*) AS events, max("ts") AS latest FROM "agent_events" GROUP BY 1;
```

## What is in the lake

- `agent_events`: one row per log record or span from every agent scout writes telemetry for
  (e.g. Claude Code, Claude (claude.ai), Cursor, GitHub Copilot), loaded hourly.
- 18 metadata tables mirrored daily from TraceForce: devices, accounts, installs,
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
  execution history.
- **GCP:** failed loads show in the BigQuery Data Transfer console — the two scheduled queries
  that ingest `agent_events` and mirror the metadata tables. The metadata mirror is a MERGE, so
  re-running it loads nothing twice. Until scout's first upload lands, the hourly ingest fails
  with "Cannot query hive partitioned data ... without any associated files"; that is expected on
  a new deployment and clears on its own once the first object arrives.
- **Azure:** `SELECT * FROM TABLE("traceforce_lakehouse".INFORMATION_SCHEMA.TASK_HISTORY(ERROR_ONLY => TRUE))`
  in Snowsight (with a warehouse active) shows any failed scheduled Task (the hourly ingest, or any
  of the 18 daily export mirrors) with Snowflake's own real error message; set
  `alarm_notification_email` to also get emailed. The metadata mirrors are each a MERGE, so
  re-running one loads nothing twice, and one
  table failing never blocks the other 17 (they're independent Tasks).

## More

- `docs/EXPORT_CONTRACT.md`: the snapshot format TraceForce writes into your bucket.
- Licence: Apache 2.0, see `LICENSE`.
