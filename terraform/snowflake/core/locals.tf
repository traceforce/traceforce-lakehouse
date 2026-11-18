locals {
  # Fixed names: the skill, docs and Snowflake examples all assume them. The database name uses an
  # underscore because Snowflake's unquoted identifiers reject hyphens.
  database_name = "traceforce_lakehouse"
  schema_name   = "traceforce"

  # "name:type" -> { name, type }.
  export_columns = {
    for t, cols in module.schema.export_tables : t => [
      for c in cols : { name = split(":", c)[0], type = split(":", c)[1] }
    ]
  }
}
