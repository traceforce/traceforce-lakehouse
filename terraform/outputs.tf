output "athena_workgroup" { value = aws_athena_workgroup.lakehouse.name }

output "athena_catalog" {
  description = "Catalog to select in Athena for the Iceberg tables."
  value       = "s3tablescatalog/${local.name}"
}

output "agent_events_fqn" {
  description = "Fully qualified table name for Athena SQL."
  value       = local.agent_events_fqn
}

output "state_machine_arn" { value = aws_sfn_state_machine.ingest.arn }

output "query_policy_json" {
  description = "Read-only IAM policy for querying the lakehouse. Attach it to the users or roles your engineers use with Claude Code."
  value       = jsonencode(local.query_policy)
}

output "query_role_arn" {
  description = "ARN of the read-only role a separate team assumes to query the lakehouse. Null unless query_trusted_principals is set."
  value       = length(var.query_trusted_principals) > 0 ? aws_iam_role.query[0].arn : null
}

output "exports_root" {
  description = "Where TraceForce's export job writes <table>/dt=YYYY-MM-DD/<HHMMSS>.jsonl.gz"
  value       = local.exports_root
}
