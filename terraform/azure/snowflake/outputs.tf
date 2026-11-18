output "azure_consent_url" {
  description = "Grant admin consent here for Snowflake's generated service principal before the role assignments can succeed."
  value       = snowflake_external_volume.lakehouse.describe_output[0].storage_locations[0].azure_storage_location[0].azure_consent_url
}

output "reader_role_name" {
  description = "Snowflake role to GRANT to whoever should query the lakehouse (query_role.tf), already quoted: GRANT ROLE <this> TO USER <them>. Not needed if you set reader_users or query_user_public_key."
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

output "query_user_name" {
  description = "Login name of the module-created read-only query user (query_role.tf). Null unless query_user_public_key is set."
  value       = var.query_user_public_key == null ? null : snowflake_service_user.query[0].name
}

output "query_warehouse_name" {
  description = "The warehouse readers run on (the skill, the dashboards)."
  value       = snowflake_warehouse.query.name
}

output "dashboard_settings" {
  description = "Paste into the TraceForce console's Settings › Lakehouse to turn on the dashboards: terraform output -json dashboard_settings. Identifiers and URLs, not secrets. Null unless dashboard_sign_in is set."
  value = var.dashboard_sign_in == null ? null : {
    account     = "${try(local.dashboards_lookup["ORG"], "")}-${try(local.dashboards_lookup["ACCOUNT"], "")}"
    account_url = local.dashboard_account_url
    database    = snowflake_database.lakehouse.name
    schema      = snowflake_schema.lakehouse.name
    warehouse   = snowflake_warehouse.query.name
    role        = snowflake_account_role.reader.name
    snowflake = local.snowflake_signin == null ? null : {
      client_id     = try(local.dashboards_lookup["CLIENT_ID"], null)
      authorize_url = "${local.dashboard_account_url}/oauth/authorize"
      # The role quoted: Snowflake matches session:role:traceforce_lakehouse_reader to an uppercase role.
      scope        = "refresh_token session:role:${snowflake_account_role.reader.fully_qualified_name}"
      redirect_uri = local.dashboard_redirect_uri
      token_url    = "https://${azurerm_function_app_flex_consumption.relay[0].default_hostname}/api/token"
    }
    external = local.external_signin == null ? null : {
      # The role these viewers query as, and the scope their token must carry: Entra writes delegated
      # scopes as session:scope:<role>, Okta and custom servers as session:role:<role>.
      role      = snowflake_account_role.dashboard[0].name
      scope     = "${local.external_provider == "entra" ? "session:scope" : "session:role"}:${snowflake_account_role.dashboard[0].name}"
      provider  = local.external_provider
      tenant_id = local.external_signin.tenant_id
      issuer    = local.external_issuer
      audience  = local.external_signin.audience
    }
  }
}
