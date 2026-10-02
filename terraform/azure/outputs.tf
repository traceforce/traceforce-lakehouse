output "azure_consent_url" {
  description = "Grant admin consent here for Snowflake's generated service principal before the role assignments can succeed."
  value       = snowflake_external_volume.lakehouse.describe_output[0].storage_locations[0].azure_storage_location[0].azure_consent_url
}

output "reader_role_name" {
  description = "Snowflake role to GRANT to whoever should query the lakehouse (query_role.tf), already quoted: GRANT ROLE <this> TO USER <them>. Not needed if you set reader_users."
  value       = snowflake_account_role.reader.fully_qualified_name
}

output "agent_events_fqn" {
  description = "Fully qualified table name for Snowflake SQL."
  value       = snowflake_iceberg_table.agent_events.fully_qualified_name
}

output "exports_root" {
  description = "Where TraceForce's export job writes <table>/dt=YYYY-MM-DD/<HHMMSS>.jsonl.gz"
  value       = local.exports_root
}
