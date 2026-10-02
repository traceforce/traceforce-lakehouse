# Canonical lakehouse column lists -- the SINGLE source of truth, shared by the three cloud modules
# (../aws, ../gcp, ../azure) and tools/gen_skill_reference.py. Edit columns.json only; each module
# consumes these outputs and applies its own engine type-map (AWS's Iceberg/Glue types, GCP's
# bq_type, Azure's snowflake_type).
#
# Source types are the platform/Iceberg tokens string, int, long, double, boolean, timestamp
# (Postgres -> uuid/text = string, integer = int, bigint = long, numeric = double, boolean,
# timestamptz = timestamp (UTC); jsonb/array = string).
locals {
  schema = jsondecode(file("${path.module}/columns.json"))
}

output "agent_events" {
  description = "agent_events columns: [{ name, type, required }]."
  value       = local.schema.agent_events
}

output "export_tables" {
  description = "The 18 metadata mirror tables: { <table> = [\"name:type\", ...] }."
  value       = local.schema.export_tables
}
