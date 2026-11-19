# A stage authenticates through a STORAGE INTEGRATION; the external volume cannot serve it.
# Allowed locations are only the two subtrees the lakehouse reads, so it grants nothing else in
# the logs bucket. The role it names is created in iam.tf after this exists: Snowflake accepts a
# role that doesn't exist yet.
resource "snowflake_storage_integration_aws" "raw" {
  depends_on                = [snowflake_execute.session_warehouse] # checks.tf: fail fast
  name                      = "traceforce_lakehouse_raw"
  enabled                   = true
  storage_provider          = "S3"
  storage_aws_role_arn      = local.raw_role_arn
  storage_allowed_locations = [local.telemetry_url, local.exports_url]
}

# One stage per subtree: a stage URL must sit inside the integration's allowed locations.
# Snowflake won't change a stage's URL while external tables use it, so the names carry a hash of
# the logs bucket and prefix: a new bucket or prefix renames the stages, which replaces core's
# external tables (their location names the stage), so no table uses a stage while its URL changes.
locals {
  stage_suffix = substr(sha256("${var.logs_bucket}/${var.logs_prefix}"), 0, 8)
}

resource "snowflake_stage_external_s3" "raw_telemetry" {
  name                = "raw_landing_zone_telemetry_${local.stage_suffix}"
  database            = module.core.database_name
  schema              = module.core.schema_name
  url                 = local.telemetry_url
  storage_integration = snowflake_storage_integration_aws.raw.name

  file_format {
    json {}
  }
}

resource "snowflake_stage_external_s3" "raw_exports" {
  name                = "raw_landing_zone_exports_${local.stage_suffix}"
  database            = module.core.database_name
  schema              = module.core.schema_name
  url                 = local.exports_url
  storage_integration = snowflake_storage_integration_aws.raw.name

  file_format {
    json {}
  }
}
