locals {
  # Fixed names: the skill, docs and Snowflake examples all assume them. Snowflake's unquoted
  # identifiers don't allow hyphens, so the database name swaps in an underscore where the AWS
  # table bucket and this module's own container (var.container_name) use one.
  database_name = "traceforce_lakehouse"
  schema_name   = "traceforce"
}
