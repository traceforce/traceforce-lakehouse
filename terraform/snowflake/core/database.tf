resource "snowflake_database" "lakehouse" {
  name = local.database_name
}

resource "snowflake_schema" "lakehouse" {
  database = snowflake_database.lakehouse.name
  name     = local.schema_name
}
