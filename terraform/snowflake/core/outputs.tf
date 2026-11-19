output "database_name" {
  description = "The lakehouse database, for the calling module's stages."
  value       = snowflake_database.lakehouse.name
}

output "schema_name" {
  description = "The lakehouse schema, for the calling module's stages."
  value       = snowflake_schema.lakehouse.name
}

output "reader_role_name" {
  description = "Snowflake role to GRANT to whoever should query the lakehouse (query_role.tf), already quoted: GRANT ROLE <this> TO USER <them>. Not needed if you set reader_users or query_user_public_key."
  value       = snowflake_account_role.reader.fully_qualified_name
}

output "agent_events_fqn" {
  description = "Fully qualified table name for Snowflake SQL."
  value       = snowflake_iceberg_table.agent_events.fully_qualified_name
}

output "query_user_name" {
  description = "Login name of the module-created read-only query user (query_role.tf). Null unless query_user_public_key is set."
  value       = var.query_user_public_key == null ? null : snowflake_service_user.query[0].name
}

output "query_warehouse_name" {
  description = "The warehouse readers run on (the skill, the dashboards)."
  value       = snowflake_warehouse.query.name
}

output "dashboard_sign_in" {
  description = "What the TraceForce UI dashboards need to sign viewers in (dashboard_sign_in.tf), or null. Identifiers, not secrets."
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
