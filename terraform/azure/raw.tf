locals {
  # "name:type" -> { name, type }. All columns come through as strings here (cast happens
  # later, in the mirror MERGE SQL).
  export_columns = {
    for t, cols in module.schema.export_tables : t => [
      for c in cols : { name = split(":", c)[0], type = split(":", c)[1] }
    ]
  }
}

# A stage needs an actual STORAGE INTEGRATION object to authenticate against -- the external
# volume (external_volume.tf) doesn't work for this, even though both end up sharing the same
# underlying Azure AD service principal per Snowflake account/tenant.
# Scoped to the raw landing container only -- never the Iceberg container -- so this integration
# can't accidentally grant write-side access to the raw logs.
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
# One compact JSON document per line, kept as VARIANT (value, not value::string): with
# TYPE = JSON, Snowflake has already parsed each file by the time any column's `as` expression
# runs, so casting back to a string just to PARSE_JSON it again downstream was a pointless round
# trip, and capped every doc at VARCHAR's 16 MB default on a large upload. A malformed/non-JSON
# file produces zero rows at the file-format layer itself either way, so VARCHAR bought no extra
# resilience here. agent/dt come from the Hive key=value path segments via METADATA$FILENAME --
# no crawler needed, but this needs an explicit REFRESH before new files are visible (ingest.tf's
# hourly Task issues it).
resource "snowflake_external_table" "raw_telemetry" {
  # Not otherwise implied by the resource graph: needs the Reader role assignment to have
  # actually propagated (role_assignments.tf's time_sleep), or its first LIST against the raw
  # container 403s with AuthorizationPermissionMismatch.
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
  # Fixed path segments *after* logs_prefix (whatever its own depth): telemetry/agent=X/dt=Y/
  # <serial>/<email>/<session>/<file> -- so agent/dt sit at fixed NEGATIVE offsets from the end
  # regardless of prefix depth. Snowflake's partition-column expressions only accept a small
  # whitelist (confirmed: SPLIT_PART works, REGEXP_SUBSTR does not -- 091065/42601).
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

# 18 snapshot external tables: typed-as-string NDJSON, one per TraceForce daily export under
#   <container_root>/<prefix>/_traceforce/lakehouse/exports/<table>/dt=YYYY-MM-DD/<HHMMSS>.jsonl.gz
# Never queried directly -- the mirror MERGE (ingest.tf) reads these and casts into the typed
# Iceberg tables (tables.tf).
resource "snowflake_external_table" "export_src" {
  for_each = local.export_columns

  # Same ordering requirement as raw_telemetry above.
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

  # <table>/dt=YYYY-MM-DD/<HHMMSS>.jsonl.gz -- dt is always 2nd-from-last regardless of prefix
  # depth. Same SPLIT_PART-only restriction as raw_telemetry above.
  column {
    name = "dt"
    type = "VARCHAR"
    as   = "split_part(split_part(metadata$filename, '/', -2), '=', 2)"
  }
}
