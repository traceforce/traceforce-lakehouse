data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# Read at plan time, so a Snowflake account in the wrong cloud or region stops the plan before
# anything is created (checks.tf). A preview data source: the caller's provider block must list
# snowflake_current_account_datasource in preview_features_enabled.
data "snowflake_current_account" "this" {}

locals {
  # Prefix of this module's AWS resource names.
  name = "traceforce-lakehouse"

  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  # Where scout's OTel exporter writes activity objects -- Hive key=value for agent and upload day (UTC):
  #   s3://<bucket>/<prefix>/telemetry/agent=<AGENT_IDENTITY_*>/dt=<YYYYMMDD>/<serial>/<email>[_<org>]/<session>/<ts>_<uuid>_logs|traces.json.gz
  # TraceForce's daily metadata snapshots land under <prefix>/_traceforce/lakehouse/exports/.
  prefix_slash  = var.logs_prefix == "" ? "" : "${var.logs_prefix}/"
  bucket_arn    = "arn:${local.partition}:s3:::${var.logs_bucket}"
  telemetry_url = "s3://${var.logs_bucket}/${local.prefix_slash}telemetry/"
  exports_url   = "s3://${var.logs_bucket}/${local.prefix_slash}_traceforce/lakehouse/exports/"
  exports_root  = local.exports_url # same value as the Athena module's exports_root output

  # Derived, so customers need no globally unique input: S3 bucket names are global.
  iceberg_bucket = "${local.name}-iceberg-${local.account_id}-${local.region}"

  # Composed, not read from the role resources: the storage integration and external volume
  # need the ARNs before the roles exist (Snowflake accepts a role that doesn't exist yet).
  raw_role_name     = "${local.name}-snowflake-raw"
  iceberg_role_name = "${local.name}-snowflake-iceberg"
  raw_role_arn      = "arn:${local.partition}:iam::${local.account_id}:role/${local.raw_role_name}"
  iceberg_role_arn  = "arn:${local.partition}:iam::${local.account_id}:role/${local.iceberg_role_name}"

  # CURRENT_REGION() for a Snowflake account in the logs bucket's region, e.g. AWS_US_EAST_2.
  # Organizations with accounts in several region groups get a prefix (PUBLIC.AWS_US_EAST_2).
  snowflake_region_expected = "AWS_${upper(replace(local.region, "-", "_"))}"
  snowflake_region          = data.snowflake_current_account.this.region
}
