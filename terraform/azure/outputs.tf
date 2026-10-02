output "azure_consent_url" {
  description = "Grant admin consent here for Snowflake's generated service principal before the role assignments can succeed."
  value       = snowflake_external_volume.lakehouse.describe_output[0].storage_locations[0].azure_storage_location[0].azure_consent_url
}

output "reader_role_name" {
  description = "Snowflake role to GRANT to whoever should query the lakehouse (query_role.tf) -- already quoted (a case-preserved lowercase identifier), so substitute it as-is: GRANT ROLE <this> TO USER <them>, not GRANT ROLE \"<this>\" (that would double the quotes). Not needed if you set reader_users instead."
  value       = snowflake_account_role.reader.fully_qualified_name
}
