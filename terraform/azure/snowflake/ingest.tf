# Snowflake Tasks on the compute.tf warehouse run the ingest and export SQL. Cadence matches
# AWS/GCP: ingest hourly at :57, export mirror daily at 12:30 UTC.
locals {
  # External tables cache their file list, so the REFRESH must precede the INSERT. A Task body
  # accepts exactly one statement (multi_statement_count does not change that), hence the
  # EXECUTE IMMEDIATE Scripting block around both.
  # The REFRESH is unscoped and re-lists all of telemetry/ each hour, so its cost grows with the
  # history kept there (this module sets no retention): a scoped REFRESH would need one statement
  # per agent per day, and Event Grid auto-refresh needs INTEGRATION at CREATE, which
  # snowflake_external_table does not expose. Accepted: auto-refresh would mean Event Grid
  # resources in the customer's logs account and a second admin consent, while the listing is
  # one metadata call per hour whose cost grows only with the object count.
  hourly_ingest_sql = <<-SQL
    EXECUTE IMMEDIATE $$
      BEGIN
        ALTER EXTERNAL TABLE ${snowflake_external_table.raw_telemetry.fully_qualified_name} REFRESH;
        ${templatefile("${path.module}/sql/ingest_agent_events.sql.tftpl", {
  target = snowflake_iceberg_table.agent_events.fully_qualified_name
  raw    = snowflake_external_table.raw_telemetry.fully_qualified_name
  cols   = join(", ", [for c in module.schema.agent_events : "\"${c.name}\""])
  # cols is quoted lowercase for the Iceberg table; select_cols is unquoted for flat's aliases.
  # Same order, so the positional INSERT holds.
  select_cols   = join(", ", [for c in module.schema.agent_events : c.name])
  lookback_days = var.lookback_days
})};
      END;
    $$
  SQL

# One Task per export table: one bad table cannot abort the others, and TASK_HISTORY reports
# each failure on its own (a single fan-out Task could not: RETURN_VALUE is NULL for an anonymous
# EXECUTE IMMEDIATE block and RESULT_SCAN errors on the failed runs).
export_mirror_sql = {
  for t, cols in local.export_columns : t => <<-SQL
    EXECUTE IMMEDIATE $$
      BEGIN
        ALTER EXTERNAL TABLE ${snowflake_external_table.export_src[t].fully_qualified_name} REFRESH;
        ${templatefile("${path.module}/sql/mirror_export_merge.sql.tftpl", {
  target  = snowflake_iceberg_table.export[t].fully_qualified_name
  source  = snowflake_external_table.export_src[t].fully_qualified_name
  columns = cols
  })};
        ${templatefile("${path.module}/sql/mirror_export_delete.sql.tftpl", {
  target = snowflake_iceberg_table.export[t].fully_qualified_name
  source = snowflake_external_table.export_src[t].fully_qualified_name
})};
      END;
    $$
  SQL
}
}

resource "snowflake_task" "ingest" {
  name          = "ingest_agent_events"
  database      = snowflake_database.lakehouse.name
  schema        = snowflake_schema.lakehouse.name
  warehouse     = snowflake_warehouse.lakehouse.name
  sql_statement = local.hourly_ingest_sql

  started = true

  # The templates' CURRENT_DATE() must be the UTC day, as on AWS/GCP.
  timezone = "UTC"

  # 4 h, not the 1 h default: a lookback_days catch-up is one atomic INSERT, and a run the timeout
  # cancels rolls back and repeats identically next hour.
  user_task_timeout_ms = 14400000

  allow_overlapping_execution = "false"

  # Never auto-suspend: a suspended Task stops alerting, which looks like recovery.
  suspend_task_after_num_failures = 0

  schedule {
    using_cron = "57 * * * * UTC"
  }
}

resource "snowflake_task" "export_mirror" {
  for_each = local.export_columns

  name          = "mirror_export_${each.key}"
  database      = snowflake_database.lakehouse.name
  schema        = snowflake_schema.lakehouse.name
  warehouse     = snowflake_warehouse.lakehouse.name
  sql_statement = local.export_mirror_sql[each.key]

  started                         = true
  timezone                        = "UTC"
  allow_overlapping_execution     = "false"
  suspend_task_after_num_failures = 0

  schedule {
    using_cron = "30 12 * * * UTC"
  }
}
