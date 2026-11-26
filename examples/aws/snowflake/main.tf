# Minimal root configuration; mirrors the README. Replace the backend and values.
terraform {
  required_version = ">= 1.5"
  backend "s3" {
    bucket = "acme-terraform-state" # NOT the logs bucket
    key    = "traceforce-lakehouse/terraform.tfstate"
    region = "us-east-1"
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.44.0"
    }
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = ">= 2.19.0, < 3.0.0"
    }
  }
}

provider "aws" {
  region = "us-east-1" # must be the logs bucket's region
}

provider "snowflake" {
  organization_name = "acmeorg"        # Snowsight account selector, top-left
  account_name      = "acmeaccount"    # the account name, not the account locator; the account must be on AWS in the logs bucket's region
  user              = "acmedeployuser" # the Snowflake user Terraform authenticates as; needs a default warehouse (README)
  role              = "ACCOUNTADMIN"   # the module creates a resource monitor, integrations and an external volume, which only this role can
  authenticator     = "SNOWFLAKE_JWT"  # key-pair auth; this module always uses it, not a choice

  # private_key is the one real secret here -- deliberately not set above like the rest:
  # reads from SNOWFLAKE_PRIVATE_KEY in the environment, never hardcoded in this file.

  # preview_features_enabled is required: several resource types this module needs (external
  # tables, Iceberg tables, email notifications, alerts) and the account lookup it uses to check
  # the region are still preview-status in the provider.
  preview_features_enabled = [
    "snowflake_external_table_resource",
    "snowflake_iceberg_table_resource",
    "snowflake_email_notification_integration_resource",
    "snowflake_alert_resource",
    "snowflake_current_account_datasource",
  ]
}

module "traceforce_lakehouse" {
  source      = "../../../terraform/aws/snowflake" # customers: github.com/traceforce/traceforce-lakehouse//terraform/aws/snowflake?ref=1.9.0
  logs_bucket = "acme-traceforce-logs"
  logs_prefix = "traceforce" # "" if TraceForce writes at the bucket root

  # logs_kms_key_arn           = "arn:aws:kms:us-east-1:111122223333:key/..." # only if the logs bucket uses SSE-KMS with your own key
  # warehouse_size             = "SMALL"       # default XSMALL; the scheduled Tasks' warehouse: bump for a lookback_days catch-up
  # query_warehouse_size       = "SMALL"       # default XSMALL; the warehouse readers query on: bump if queries feel slow
  # alarm_notification_email   = "jdoe@acme.com" # a verified Snowflake user's email, not a team address -- get notified when a scheduled Task fails
  # query_user_public_key      = "MIIBIjAN..."  # one-line public key body: creates traceforce_lakehouse_query, a reader-only service user
  # reader_users               = ["JDOE"]       # exact stored Snowflake usernames (uppercase unless created quoted) granted read-only access
  # credit_notification_users  = ["JDOE"]       # exact stored usernames with verified emails, emailed as credit usage climbs (the monitor never suspends the warehouse)
  # dashboard_sign_in          = { console_origin = "https://<TraceForce console>", snowflake = {} } # TraceForce dashboards: viewers sign in to Snowflake (README)
}

output "reader_role_name" {
  description = "Snowflake role to grant to whoever should query the lakehouse."
  value       = module.traceforce_lakehouse.reader_role_name
}

output "agent_events_fqn" {
  description = "Fully qualified name of the agent_events table, for Snowflake SQL."
  value       = module.traceforce_lakehouse.agent_events_fqn
}

# output "dashboard_settings" { value = module.traceforce_lakehouse.dashboard_settings } # with dashboard_sign_in (README)
