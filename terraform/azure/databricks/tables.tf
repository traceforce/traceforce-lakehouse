locals {
  databricks_type = {
    string    = "string"
    int       = "int"
    long      = "bigint"
    double    = "double"
    boolean   = "boolean"
    timestamp = "timestamp_ntz" # UTC, as Snowflake's TIMESTAMP_NTZ(6)
  }

  # { <table> = [{ name, type }] } from columns.json's "name:type" lists.
  export_columns = {
    for t, cols in local.export_tables : t => [
      for c in cols : { name = split(":", c)[0], type = split(":", c)[1] }
    ]
  }

  # Each table's columns as Databricks sees them.
  agent_events_table_columns = [
    for c in local.agent_events_columns : {
      name = c.name, type = local.databricks_type[c.type], nullable = !c.required
    }
  ]
  export_table_columns = {
    for t, cols in local.export_columns : t => [
      for c in cols : { name = c.name, type = local.databricks_type[c.type], nullable = c.name != "id" }
    ]
  }

  # The run log (_ingest_runs below), by name rather than the table's id: the id is unknown while
  # the table is being replaced (a column change), which made every SQL file that names it show as
  # changing, and the databricks provider then fails the apply when the file turns out the same
  # ("inconsistent final plan", .md5). The view and the jobs depend on the table explicitly.
  runs_table = "${local.catalog_name}.${local.schema_name}._ingest_runs"

  # The run log's columns: one row per completed run of each script. Times UTC.
  ingest_runs_columns = [
    { name = "table_name", type = "string", nullable = false },
    { name = "run_id", type = "string", nullable = true },
    { name = "started_at", type = "timestamp_ntz", nullable = true },
    { name = "finished_at", type = "timestamp_ntz", nullable = true },
    # mirror runs: the newest snapshot file listed in the window, the one merged, the mirror's rows
    { name = "listed_path", type = "string", nullable = true },
    { name = "listed_dt", type = "date", nullable = true },
    { name = "listed_at", type = "timestamp_ntz", nullable = true },
    { name = "listed_files", type = "bigint", nullable = true },
    { name = "merged", type = "boolean", nullable = true },
    { name = "merged_path", type = "string", nullable = true },
    # rows the MERGE wrote: every row that matched (rewritten even when unchanged) plus inserts and deletes
    { name = "rows_merged", type = "bigint", nullable = true },
    { name = "mirror_rows", type = "bigint", nullable = true },
    # ingest runs: the newest upload in the window (information only), the rows inserted
    { name = "newest_upload_at", type = "timestamp_ntz", nullable = true },
    { name = "upload_files", type = "bigint", nullable = true },
    { name = "rows_inserted", type = "bigint", nullable = true },
  ]

  # Iceberg format version 2 on every table: row-level MERGE/DELETE work on it, it matches the
  # Snowflake module (Snowflake's default) and every Iceberg reader handles it.
  iceberg_properties = { "format-version" = "2" }
}

# Managed Iceberg tables in the catalog's storage root (the module's Iceberg container),
# unpartitioned as in the Snowflake module. This relies on undocumented provider behaviour:
# databricks_sql_table documents data_source_format for external tables only, but passes the value
# into its CREATE TABLE ... USING <format>, so ICEBERG creates the same table as SQL's
# USING ICEBERG (securable_kind TABLE_DELTA_ICEBERG_MANAGED). Setting DELTA instead would create
# plain Delta tables.

# A columns.json change to a table recreates it, empty, as on AWS and Azure (Snowflake); see
# RELEASING.md. The provider can't alter the columns safely in place: with the same column count
# it pairs old and new columns by position and renames them (relabelling data), and it refuses
# any type change at plan time, -replace included. So column changes are ignored on the table and
# a change to its column list here replaces it instead.
resource "terraform_data" "agent_events_columns" {
  input = local.agent_events_table_columns
}

resource "terraform_data" "export_columns" {
  for_each = local.export_table_columns
  input    = each.value
}

# The table customers and Claude Code query; everything else feeds it and the metadata mirrors.
resource "databricks_sql_table" "agent_events" {
  name               = "agent_events"
  catalog_name       = databricks_catalog.lakehouse.name
  schema_name        = databricks_schema.lakehouse.name
  table_type         = "MANAGED"
  data_source_format = "ICEBERG"
  warehouse_id       = databricks_sql_endpoint.ingest.id
  properties         = local.iceberg_properties

  # Terraform-only workaround; the table itself is managed Iceberg. Unity Catalog reports managed
  # Iceberg tables with data_source_format DELTA (they keep a Delta log next to the Iceberg
  # metadata), so the provider would see DELTA != ICEBERG and replace the table on every plan.
  # column: changes replace the table through replace_triggered_by (see above).
  lifecycle {
    ignore_changes       = [data_source_format, column]
    replace_triggered_by = [terraform_data.agent_events_columns]
  }

  dynamic "column" {
    for_each = local.agent_events_table_columns
    content {
      name     = column.value.name
      type     = column.value.type
      nullable = column.value.nullable
    }
  }
}

# Metadata mirror tables, one per export table, same names as in TraceForce.
resource "databricks_sql_table" "export" {
  for_each = local.export_table_columns

  name               = each.key
  catalog_name       = databricks_catalog.lakehouse.name
  schema_name        = databricks_schema.lakehouse.name
  table_type         = "MANAGED"
  data_source_format = "ICEBERG"
  warehouse_id       = databricks_sql_endpoint.ingest.id
  properties         = local.iceberg_properties

  # Terraform-only workaround; the table itself is managed Iceberg. Unity Catalog reports managed
  # Iceberg tables with data_source_format DELTA (they keep a Delta log next to the Iceberg
  # metadata), so the provider would see DELTA != ICEBERG and replace the table on every plan.
  # column: changes replace the table through replace_triggered_by (see above).
  lifecycle {
    ignore_changes       = [data_source_format, column]
    replace_triggered_by = [terraform_data.export_columns[each.key]]
  }

  dynamic "column" {
    for_each = each.value
    content {
      name     = column.value.name
      type     = column.value.type
      nullable = column.value.nullable
    }
  }
}

resource "terraform_data" "ingest_runs_columns" {
  input = local.ingest_runs_columns
}

# The run log: every ingest and mirror run appends one row as its last statement (sql/), for the
# freshness view below. The scripts keep 60 days (the ingest deletes older rows once a day).
resource "databricks_sql_table" "ingest_runs" {
  name               = "_ingest_runs"
  catalog_name       = databricks_catalog.lakehouse.name
  schema_name        = databricks_schema.lakehouse.name
  table_type         = "MANAGED"
  data_source_format = "ICEBERG"
  warehouse_id       = databricks_sql_endpoint.ingest.id
  properties         = local.iceberg_properties

  # As on the tables above.
  lifecycle {
    ignore_changes       = [data_source_format, column]
    replace_triggered_by = [terraform_data.ingest_runs_columns]
  }

  dynamic "column" {
    for_each = local.ingest_runs_columns
    content {
      name     = column.value.name
      type     = column.value.type
      nullable = column.value.nullable
    }
  }
}

# When the run log was created: until it is older than a table's threshold, a table with no logged
# run isn't stale (freshness view), so a new deployment, or a run log recreated empty, doesn't alert
# before the first runs. Reset whenever the table is recreated (a column change or a forced
# replace): its id is unknown only then, so an in-place change to the table doesn't restart the
# grace period. Also reset when the export tables change, so a table an upgrade adds gets the same
# grace before its first mirror run (a table with a logged run doesn't use this time).
resource "time_static" "run_log" {
  triggers = { tables = join(",", keys(databricks_sql_table.export)) }
  lifecycle {
    replace_triggered_by = [databricks_sql_table.ingest_runs.id]
  }
}

# One row per table: stale or not, and why (sql/freshness_view.sql.tftpl). Read by the freshness
# alert (alerts.tf) and by readers.
resource "databricks_sql_table" "freshness" {
  name            = "freshness"
  catalog_name    = databricks_catalog.lakehouse.name
  schema_name     = databricks_schema.lakehouse.name
  table_type      = "VIEW"
  warehouse_id    = databricks_sql_endpoint.ingest.id
  view_definition = module.sql.freshness_view_sql

  depends_on = [databricks_sql_table.ingest_runs] # named in the SQL, not referenced (see local.runs_table)
}
