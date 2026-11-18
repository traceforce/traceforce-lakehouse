# Plan-time checks that stop before anything is created. (The logs bucket's region is checked on
# the Iceberg bucket, storage.tf.)
resource "terraform_data" "checks" {
  lifecycle {
    precondition {
      # Snowflake itself would read and write a bucket in another region; the module refuses it to
      # keep the data in the logs bucket's region and avoid cross-region transfer charges and
      # latency on every hourly run.
      condition     = local.snowflake_region == local.snowflake_region_expected || endswith(local.snowflake_region, ".${local.snowflake_region_expected}")
      error_message = "The Snowflake account is in ${local.snowflake_region}, but the aws provider's region (which must be the logs bucket's) is ${local.region}. Use a Snowflake account on AWS in ${local.region} (CURRENT_REGION() = ${local.snowflake_region_expected}), so data isn't moved across regions on every run. A Snowflake account on Azure uses //terraform/azure/snowflake instead."
    }
    precondition {
      condition     = length(local.iceberg_bucket) <= 63
      error_message = "The derived Iceberg bucket name ${local.iceberg_bucket} is longer than S3's 63-character limit."
    }
  }
}

# Creating the Iceberg tables (and the alert's grant in core) needs a warehouse in Terraform's own
# session, before this module's warehouse exists. No data source exposes the session's warehouse,
# so this is checked during apply; CURRENT_WAREHOUSE() needs no warehouse itself. The S3 and IAM
# resources, the integration and the volume wait for it, so a failure stops before any of them and
# before any external or Iceberg table. Core's database, warehouse and role may already exist by
# then; rerunning apply after the fix continues from there.
resource "snowflake_execute" "session_warehouse" {
  execute = "SELECT 1"
  revert  = "SELECT 1"
  query   = "SELECT COALESCE(CURRENT_WAREHOUSE(), '') AS WAREHOUSE"

  lifecycle {
    postcondition {
      condition     = length(self.query_results) > 0 && try(self.query_results[0]["WAREHOUSE"], "") != ""
      error_message = "Terraform's Snowflake session has no warehouse (or this check's query failed), and creating the Iceberg tables needs one (this module's own warehouse doesn't exist yet). Give the deploy user a default warehouse: ALTER USER <deploy user> SET DEFAULT_WAREHOUSE = <an existing warehouse>; or set warehouse = \"<an existing warehouse>\" in the snowflake provider block. Then run terraform apply again; it continues where it stopped."
    }
  }
}
