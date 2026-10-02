locals {
  # "name:type" -> { name, type }.
  export_columns = {
    for t, cols in module.schema.export_tables : t => [
      for c in cols : { name = split(":", c)[0], type = split(":", c)[1] }
    ]
  }
}

# A stage authenticates through a STORAGE INTEGRATION; the external volume cannot serve it.
# Scoped to the raw container only, so it grants nothing on the Iceberg side.
resource "snowflake_storage_integration_azure" "raw" {
  name                      = "traceforce_lakehouse_raw"
  storage_allowed_locations = [local.container_root]
  azure_tenant_id           = data.azuread_client_config.current.tenant_id
  enabled                   = true
}

resource "snowflake_stage_external_azure" "raw" {
  name                = "raw_landing_zone"
  database            = snowflake_database.lakehouse.name
  schema              = snowflake_schema.lakehouse.name
  url                 = local.container_root
  storage_integration = snowflake_storage_integration_azure.raw.name

  file_format {
    json {}
  }
}

# Ingest SOURCE: the raw gzipped OTLP-JSON objects scout writes under
#   <container_root>/<prefix>/telemetry/agent=<AGENT_IDENTITY_*>/dt=<YYYYMMDD>/...
# doc stays VARIANT because TYPE = JSON has already parsed it. A malformed line ends the scan of
# that file; rows before it still come through. auto_refresh is off, so the Task must REFRESH.
resource "snowflake_external_table" "raw_telemetry" {
  # The Reader role assignment must have propagated or the first LIST 403s.
  depends_on = [time_sleep.raw_reader_propagation]

  name         = "raw_telemetry"
  database     = snowflake_database.lakehouse.name
  schema       = snowflake_schema.lakehouse.name
  location     = "@${snowflake_stage_external_azure.raw.fully_qualified_name}/${local.prefix_slash}telemetry/"
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

# 18 snapshot external tables, one per TraceForce daily export under
#   <container_root>/<prefix>/_traceforce/lakehouse/exports/<table>/dt=YYYY-MM-DD/<HHMMSS>.jsonl.gz
# Every column is a string; the mirror MERGE (ingest.tf) casts into the Iceberg tables.
resource "snowflake_external_table" "export_src" {
  for_each = local.export_columns

  depends_on = [time_sleep.raw_reader_propagation]

  name         = "export_${each.key}"
  database     = snowflake_database.lakehouse.name
  schema       = snowflake_schema.lakehouse.name
  location     = "@${snowflake_stage_external_azure.raw.fully_qualified_name}/${local.prefix_slash}_traceforce/lakehouse/exports/${each.key}/"
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
