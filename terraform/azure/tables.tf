# Snowflake's normalized forms, not the SQL aliases (INT, BIGINT): DESCRIBE reports these back and
# column.type is force-new, so an alias would make every plan a destroy-and-recreate. Bare STRING
# and TIMESTAMP_NTZ fail at create (42601): Iceberg needs the exact 134217728 length and scale 6.
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

# The table customers and Claude Code query; everything else feeds it and its 18 siblings.
# Unpartitioned: partition_by on a time column crashes the provider (v2.21.0, nil assertion in
# parseIcebergTablePartitionTime); revisit on a newer provider.
# catalog = "SNOWFLAKE" is the keyword for Snowflake-managed, not a catalog integration name.
resource "snowflake_iceberg_table" "agent_events" {
  # The Contributor and Delegator role assignments must have propagated or create fails.
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

# 18 metadata mirror tables: typed Iceberg, same names as in TraceForce (the export_ sources
# are in raw.tf).
resource "snowflake_iceberg_table" "export" {
  for_each = local.export_columns

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
