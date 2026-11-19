# Where core's Iceberg tables write. Like the integration, it names a role that iam.tf creates
# afterwards from this volume's describe_output.
resource "snowflake_external_volume" "lakehouse" {
  depends_on = [snowflake_execute.session_warehouse] # checks.tf: fail fast
  name       = "traceforce_lakehouse"

  storage_location {
    storage_location_name = local.name
    storage_provider      = "S3"
    storage_base_url      = "s3://${aws_s3_bucket.iceberg.bucket}/"
    storage_aws_role_arn  = local.iceberg_role_arn
  }
}
