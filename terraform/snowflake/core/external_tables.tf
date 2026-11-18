# Ingest SOURCE: the raw gzipped OTLP-JSON objects scout writes under
#   <logs root>/<prefix>/telemetry/agent=<AGENT_IDENTITY_*>/dt=<YYYYMMDD>/...
# doc stays VARIANT because TYPE = JSON has already parsed it. A malformed line ends the scan of
# that file; rows before it still come through. auto_refresh is off, so the Task must REFRESH.
resource "snowflake_external_table" "raw_telemetry" {
  # Read access to the raw logs must have propagated or the first LIST fails.
  depends_on = [terraform_data.raw_ready]

  name         = "raw_telemetry"
  database     = snowflake_database.lakehouse.name
  schema       = snowflake_schema.lakehouse.name
  location     = var.telemetry_location
  file_format  = "TYPE = JSON"
  auto_refresh = false
  partition_by = ["agent", "dt"]

  column {
    name = "doc"
    type = "VARIANT"
    as   = "value"
  }
  # agent/dt sit at fixed negative offsets from the end of METADATA$FILENAME, so logs_prefix
  # depth does not matter. Partition expressions accept SPLIT_PART but not REGEXP_SUBSTR.
  column {
    name = "agent"
    type = "VARCHAR"
    as   = "split_part(split_part(metadata$filename, '/', -6), '=', 2)"
  }
  column {
    name = "dt"
    type = "VARCHAR"
    as   = "split_part(split_part(metadata$filename, '/', -5), '=', 2)"
  }
}

# Snapshot external tables, one per TraceForce daily export under
#   <logs root>/<prefix>/_traceforce/lakehouse/exports/<table>/dt=YYYY-MM-DD/<HHMMSS>.jsonl.gz
# Every column is a string; the mirror MERGE (ingest.tf) casts into the Iceberg tables.
resource "snowflake_external_table" "export_src" {
  for_each = local.export_columns

  depends_on = [terraform_data.raw_ready]

  name         = "export_${each.key}"
  database     = snowflake_database.lakehouse.name
  schema       = snowflake_schema.lakehouse.name
  location     = "${var.exports_location_prefix}${each.key}/"
  file_format  = "TYPE = JSON"
  auto_refresh = false
  partition_by = ["dt"]

  dynamic "column" {
    for_each = each.value
    content {
      name = column.value.name
      type = "VARCHAR"
      as   = "value:${column.value.name}::string"
    }
  }

  # dt is the 2nd-from-last path segment regardless of prefix depth.
  column {
    name = "dt"
    type = "VARCHAR"
    as   = "split_part(split_part(metadata$filename, '/', -2), '=', 2)"
  }
}
