# Schedules the ingest/export SQL rewrite (raw.tf/tables.tf) on the compute.tf warehouse.
# Cadence matches AWS/GCP:
# hourly at :57 for ingest, daily at 12:30 UTC for the export mirror.
locals {
  # Two statements, not one: unlike Athena's partition projection, Snowflake external tables
  # cache their own file listing at creation/last-refresh time, so new objects aren't visible to
  # a query until an explicit REFRESH runs first. REFRESH failing should abort the run (the
  # INSERT would otherwise read a stale file listing) -- exactly what the TASK_HISTORY-polling
  # alert (compute.tf) is watching for.
  #
  # Wrapped in a Snowflake Scripting EXECUTE IMMEDIATE block, not joined as two plain
  # semicolon-separated statements: a Task's <sql> body accepts exactly one of -- a single SQL
  # statement, a call to a stored procedure, or a Scripting block -- and a plain "REFRESH;
  # INSERT ...;" body is none of those (42601: "Actual statement count 2 did not match the
  # desired statement count 1"). The task's own multi_statement_count argument doesn't help
  # here either: it wraps a client-request batching parameter unrelated to how many statements
  # a Task's stored sql_statement body may contain. The fix is the same mechanism already used
  # below for each export mirror Task: one statement whose text is itself a Scripting block.
  hourly_ingest_sql = <<-SQL
    EXECUTE IMMEDIATE $$
      BEGIN
        ALTER EXTERNAL TABLE ${snowflake_external_table.raw_telemetry.fully_qualified_name} REFRESH;
        ${templatefile("${path.module}/sql/ingest_agent_events.sql.tftpl", {
  target = snowflake_iceberg_table.agent_events.fully_qualified_name
  raw    = snowflake_external_table.raw_telemetry.fully_qualified_name
  cols   = join(", ", [for c in module.schema.agent_events : "\"${c.name}\""])
  # Unquoted and separate from cols above: flat's own column aliases are unquoted (so they fold
  # to uppercase), while cols is quoted lowercase to match the Iceberg table's own columns --
  # selecting flat's columns by the quoted lowercase form wouldn't resolve. Same source list and
  # order as cols, so the positional match into the INSERT's column list still holds.
  select_cols   = join(", ", [for c in module.schema.agent_events : c.name])
  lookback_days = var.lookback_days
})};
      END;
    $$
  SQL

# One Task per export table (18 total), not one Task fanning out across all 18 with its own
# hand-rolled per-table error catching: a single shared Task would need to reconstruct, by hand,
# two things a plain Task already gives for free -- per-unit failure isolation (one bad table
# can't abort the others) and per-unit diagnostics (TASK_HISTORY's own ERROR_MESSAGE, since
# RETURN_VALUE stays NULL for an anonymous EXECUTE IMMEDIATE block and RESULT_SCAN errors on
# exactly the failed runs it would need to explain). 18 Task resources buys both properties
# already built into Snowflake, with zero custom error-aggregation code.
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

  # No overlapping runs. Snowflake's actual parameter name is allow_overlapping_execution,
  # already false by default, set explicitly for documentation.
  allow_overlapping_execution = "false"

  # Snowflake auto-suspends a Task after 10 consecutive failures by default -- a suspended
  # Task stops running (and alerting) entirely, which looks like a recovery, not an outage.
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

  started                     = true
  allow_overlapping_execution = "false"
  # See the ingest Task above for why this is disabled.
  suspend_task_after_num_failures = 0

  schedule {
    using_cron = "30 12 * * * UTC"
  }
}
