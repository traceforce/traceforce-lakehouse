# Canonical lakehouse column lists -- the SINGLE source of truth, shared by both cloud modules
# (../aws, ../gcp) and tools/gen_skill_reference.py. Edit columns.json only; each module consumes
# these outputs and applies its own engine type-map (GCP's bq_type, AWS's Iceberg/Glue types).
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

output "agent_identities" {
  description = "AgentIdentity enum name -> integer code, generated from scout-proto by tools/gen_agent_identities.py."
  value       = jsondecode(file("${path.module}/agent_identities.json")).identities
}
