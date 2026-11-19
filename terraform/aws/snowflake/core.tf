# The Snowflake objects that don't depend on the cloud: database, warehouse, tables, Tasks, alert
# and reader access. This module supplies the S3 side. No depends_on on this block: the stages
# need core's schema and core's external tables need the stages, which is fine resource by
# resource but would be a cycle at module level.
module "core" {
  source = "../../snowflake/core"

  external_volume_name    = snowflake_external_volume.lakehouse.name
  telemetry_location      = "@${snowflake_stage_external_s3.raw_telemetry.fully_qualified_name}/"
  exports_location_prefix = "@${snowflake_stage_external_s3.raw_exports.fully_qualified_name}/"
  raw_ready               = time_sleep.raw_reader_propagation.id
  iceberg_ready           = time_sleep.iceberg_write_propagation.id

  warehouse_size            = var.warehouse_size
  query_warehouse_size      = var.query_warehouse_size
  alarm_notification_email  = var.alarm_notification_email
  lookback_days             = var.lookback_days
  reader_users              = var.reader_users
  credit_notification_users = var.credit_notification_users
  query_user_public_key     = var.query_user_public_key
  dashboard_sign_in         = var.dashboard_sign_in
}
