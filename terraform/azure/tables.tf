# Snowflake's Iceberg tables take standard SQL column types, not raw Iceberg type tokens, so the
# schema's six source types need translating here. A bare "STRING"/"TIMESTAMP_NTZ" both 42601:
# STRING needs an explicit length (Iceberg requires the exact 134217728 max, not Snowflake's
# classic VARCHAR default) and TIMESTAMP_NTZ needs an explicit scale (Iceberg only supports
# microsecond precision, scale 6, not Snowflake's nanosecond default, scale 9).
#
# int/long/double MUST use Snowflake's own normalized form, not the plain SQL aliases
# ("INT"/"BIGINT"/"DOUBLE") CREATE ICEBERG TABLE also accepts: DESCRIBE TABLE reports back the
# narrower real width Iceberg actually stores (NUMBER(10, 0) for INT, NUMBER(19, 0) for BIGINT),
# not the alias, and every `terraform plan` diffs refreshed state against this literal string.
# column.type is force-new here, so an alias/normalized-form mismatch doesn't just nag as a
# no-op diff -- it makes every plan a silent destroy-and-recreate of the whole table.
locals {
  snowflake_type = {
    string    = "VARCHAR(134217728)"
    int       = "NUMBER(10, 0)"
    long      = "NUMBER(19, 0)"
    double    = "FLOAT"
    boolean   = "BOOLEAN"
    timestamp = "TIMESTAMP_NTZ(6)"
  }
}

# The only place data is durably written, and the only thing customers/Claude Code query --
# everything else in this module exists to feed this table and its 18 siblings below.
#
# Unpartitioned: `partition_by { day = "ts" }` crashes the provider (v2.21.0) -- a nil type
# assertion in parseIcebergTablePartitionTime, a genuine provider bug for any time-based
# partition_by field, not a config error here. Revisit once a fixed provider version ships.
#
# catalog = "SNOWFLAKE" is the literal keyword for Snowflake managing its own catalog, not the
# name of a CATALOG INTEGRATION object -- a real catalog integration (CATALOG_SOURCE =
# OBJECT_STORE) is for reading tables another engine already wrote directly to object storage.
resource "snowflake_iceberg_table" "agent_events" {
  # Needs both the Contributor role (Iceberg container) and the Delegator role (storage
  # account) to have actually propagated (role_assignments.tf's time_sleep), or create 42601s
  # testing a user delegation key.
  depends_on = [time_sleep.iceberg_write_propagation]

  name            = "agent_events"
  database        = snowflake_database.lakehouse.name
  schema          = snowflake_schema.lakehouse.name
  external_volume = snowflake_external_volume.lakehouse.name
  catalog         = "SNOWFLAKE"
  base_location   = "agent_events"

  dynamic "column" {
    for_each = module.schema.agent_events
    content {
      name     = column.value.name
      type     = local.snowflake_type[column.value.type]
      not_null = column.value.required
    }
  }
}

# 18 metadata mirror tables: managed Iceberg, typed, same names as in TraceForce (no export_
# prefix -- that's the source side, raw.tf).
resource "snowflake_iceberg_table" "export" {
  for_each = local.export_columns

  # Same ordering requirement as agent_events above.
  depends_on = [time_sleep.iceberg_write_propagation]

  name            = each.key
  database        = snowflake_database.lakehouse.name
  schema          = snowflake_schema.lakehouse.name
  external_volume = snowflake_external_volume.lakehouse.name
  catalog         = "SNOWFLAKE"
  base_location   = each.key

  dynamic "column" {
    for_each = each.value
    content {
      name     = column.value.name
      type     = local.snowflake_type[column.value.type]
      not_null = column.value.name == "id"
    }
  }
}
