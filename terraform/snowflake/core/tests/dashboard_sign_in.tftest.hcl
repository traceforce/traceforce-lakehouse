# The dashboards' sign-in (dashboard_sign_in.tf), with a mocked snowflake provider (every run is a plan
# or an in-memory apply):
#
#   cd terraform/snowflake/core && terraform init -backend=false && terraform test
#
# Needs Terraform >= 1.7 (mock providers).

mock_provider "snowflake" {
  mock_resource "snowflake_account_role" {
    defaults = { fully_qualified_name = "\"traceforce_lakehouse_reader\"" }
  }
  mock_resource "snowflake_oauth_integration_for_custom_clients" {
    defaults = { fully_qualified_name = "\"Lakehouse\"" }
  }
  mock_resource "snowflake_external_oauth_integration" {
    defaults = { fully_qualified_name = "\"traceforce_lakehouse_dashboards_idp\"" }
  }
  mock_resource "snowflake_execute" {
    defaults = { query_results = [{ ORG = "ACME", ACCOUNT = "PROD_US", CLIENT_ID = "client+id/1=" }] }
  }
  # The provider validates identifier formats even when mocked.
  mock_resource "snowflake_database" {
    defaults = { fully_qualified_name = "\"traceforce_lakehouse\"" }
  }
  mock_resource "snowflake_schema" {
    defaults = { fully_qualified_name = "\"traceforce_lakehouse\".\"traceforce\"" }
  }
  mock_resource "snowflake_warehouse" {
    defaults = { fully_qualified_name = "\"traceforce_lakehouse\"" }
  }
  mock_resource "snowflake_external_table" {
    defaults = { fully_qualified_name = "\"traceforce_lakehouse\".\"traceforce\".\"external\"" }
  }
  mock_resource "snowflake_iceberg_table" {
    defaults = { fully_qualified_name = "\"traceforce_lakehouse\".\"traceforce\".\"iceberg\"" }
  }
}

variables {
  external_volume_name    = "traceforce_lakehouse"
  telemetry_location      = "@\"traceforce_lakehouse\".\"traceforce\".\"raw\"/pfx/telemetry/"
  exports_location_prefix = "@\"traceforce_lakehouse\".\"traceforce\".\"raw\"/pfx/_traceforce/lakehouse/exports/"
  raw_ready               = "raw-ready"
  iceberg_ready           = "iceberg-ready"
}

run "off_by_default" {
  command = plan

  assert {
    condition = (length(snowflake_oauth_integration_for_custom_clients.dashboards) == 0 && length(snowflake_external_oauth_integration.dashboards) == 0
    && length(snowflake_execute.dashboards_lookup) == 0 && length(snowflake_execute.dashboards_roles) == 0 && length(snowflake_account_role.dashboard) == 0)
    error_message = "Without dashboard_sign_in nothing is created."
  }
  assert {
    condition     = output.dashboard_sign_in == null
    error_message = "Without dashboard_sign_in the output is null."
  }
}

run "snowflake_sign_in" {
  variables {
    dashboard_sign_in = { console_origin = "https://app.example.com/", snowflake = {} }
  }
  override_resource {
    target = snowflake_execute.dashboards_roles
    values = { query_results = [
      { property = "ENABLED", property_value = "true" },
      { property = "ALLOWED_ROLES_LIST", property_value = "traceforce_lakehouse_reader" },
    ] }
  }

  assert {
    condition = alltrue([
      snowflake_oauth_integration_for_custom_clients.dashboards[0].name == "Lakehouse",
      snowflake_oauth_integration_for_custom_clients.dashboards[0].oauth_client_type == "PUBLIC",
      snowflake_oauth_integration_for_custom_clients.dashboards[0].oauth_enforce_pkce == "true",
      snowflake_oauth_integration_for_custom_clients.dashboards[0].oauth_use_secondary_roles == "NONE",
      snowflake_oauth_integration_for_custom_clients.dashboards[0].oauth_refresh_token_validity == 86400,
      snowflake_oauth_integration_for_custom_clients.dashboards[0].oauth_redirect_uri == "https://app.example.com/lakehouse/snowflake-redirect.html",
      snowflake_oauth_integration_for_custom_clients.dashboards[0].enabled == "false",
    ])
    error_message = "A public PKCE client named Lakehouse, secondary roles off, 24 h refresh, redirect to the console's page, created disabled."
  }
  assert {
    condition     = snowflake_execute.dashboards_roles[0].execute == "ALTER SECURITY INTEGRATION \"Lakehouse\" SET ALLOWED_ROLES_LIST = ('\"traceforce_lakehouse_reader\"') ENABLED = TRUE"
    error_message = "One statement sets the allowed roles to exactly the quoted reader role and enables the integration."
  }
  assert {
    condition     = strcontains(snowflake_execute.dashboards_lookup[0].query, "SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('Lakehouse')")
    error_message = "The client ID lookup must name the integration as stored (case-sensitive)."
  }
  assert {
    condition = (output.dashboard_sign_in.account == "ACME-PROD_US" && output.dashboard_sign_in.account_url == "https://acme-prod-us.snowflakecomputing.com"
    && output.dashboard_sign_in.role == "traceforce_lakehouse_reader" && output.dashboard_sign_in.warehouse == "traceforce_lakehouse_query")
    error_message = "Account identifier as ORG-ACCOUNT; URL lowercased with the underscore as a hyphen; the role's plain stored name for the SQL API; the query warehouse, not the ingest one."
  }
  assert {
    condition = (output.dashboard_sign_in.snowflake.client_id == "client+id/1=" && output.dashboard_sign_in.snowflake.authorize_url == "https://acme-prod-us.snowflakecomputing.com/oauth/authorize"
    && output.dashboard_sign_in.snowflake.scope == "refresh_token session:role:\"traceforce_lakehouse_reader\"" && output.dashboard_sign_in.external == null)
    error_message = "The browser's sign-in settings: client ID, authorize URL and the scope with the role quoted."
  }
}

# The allow-list is set outside the provider, so a plan fails if it was widened or the
# integration disabled by hand.
run "refuses_a_widened_allow_list" {
  state_key = "refuses_a_widened_allow_list" # its own state, so the override applies on create
  variables {
    dashboard_sign_in = { console_origin = "https://app.example.com", snowflake = {} }
  }
  override_resource {
    target = snowflake_execute.dashboards_roles
    values = { query_results = [
      { property = "ENABLED", property_value = "true" },
      { property = "ALLOWED_ROLES_LIST", property_value = "traceforce_lakehouse_reader,SYSADMIN" },
    ] }
  }
  expect_failures = [snowflake_execute.dashboards_roles]
}

run "refuses_an_empty_allow_list" {
  state_key = "refuses_an_empty_allow_list" # its own state, so the override applies on create
  variables {
    dashboard_sign_in = { console_origin = "https://app.example.com", snowflake = {} }
  }
  override_resource {
    target = snowflake_execute.dashboards_roles
    values = { query_results = [
      { property = "ENABLED", property_value = "true" },
      { property = "ALLOWED_ROLES_LIST", property_value = "" },
    ] }
  }
  expect_failures = [snowflake_execute.dashboards_roles]
}

run "refuses_a_disabled_integration" {
  state_key = "refuses_a_disabled_integration" # its own state, so the override applies on create
  variables {
    dashboard_sign_in = { console_origin = "https://app.example.com", snowflake = {} }
  }
  override_resource {
    target = snowflake_execute.dashboards_roles
    values = { query_results = [
      { property = "ENABLED", property_value = "false" },
      { property = "ALLOWED_ROLES_LIST", property_value = "traceforce_lakehouse_reader" },
    ] }
  }
  expect_failures = [snowflake_execute.dashboards_roles]
}

run "entra_sign_in" {
  command = plan

  variables {
    reader_users = ["JDOE"]
    dashboard_sign_in = { console_origin = "https://app.example.com", external = {
      provider = "entra", tenant_id = "11111111-2222-3333-4444-555555555555", audience = "api://traceforce-lakehouse"
    } }
  }

  assert {
    condition = alltrue([
      snowflake_external_oauth_integration.dashboards[0].external_oauth_type == "AZURE",
      snowflake_external_oauth_integration.dashboards[0].external_oauth_issuer == "https://sts.windows.net/11111111-2222-3333-4444-555555555555/",
      contains(snowflake_external_oauth_integration.dashboards[0].external_oauth_jws_keys_url, "https://login.microsoftonline.com/11111111-2222-3333-4444-555555555555/discovery/v2.0/keys"),
      contains(snowflake_external_oauth_integration.dashboards[0].external_oauth_token_user_mapping_claim, "upn"),
      snowflake_external_oauth_integration.dashboards[0].external_oauth_snowflake_user_mapping_attribute == "login_name",
      snowflake_external_oauth_integration.dashboards[0].external_oauth_any_role_mode == "DISABLE",
    ])
    error_message = "Entra: issuer and keys from the tenant, upn mapped to the login name, no role outside the list."
  }
  assert {
    condition = (snowflake_account_role.dashboard[0].name == "TRACEFORCE_LAKEHOUSE_DASHBOARD"
      && snowflake_external_oauth_integration.dashboards[0].external_oauth_allowed_roles_list == toset(["TRACEFORCE_LAKEHOUSE_DASHBOARD"])
    && snowflake_external_oauth_integration.dashboards[0].enabled == true)
    error_message = "Company sign-in gets its own uppercase role, the only one the integration allows, set as it's created."
  }
  assert {
    condition     = snowflake_grant_account_role.dashboard_reader[0].parent_role_name == "TRACEFORCE_LAKEHOUSE_DASHBOARD" && length(snowflake_oauth_integration_for_custom_clients.dashboards) == 0
    error_message = "The dashboard role inherits the reader role; no Snowflake OAuth integration without snowflake = {}."
  }
  assert {
    condition     = toset(keys(snowflake_grant_account_role.dashboard_users)) == toset(["JDOE"])
    error_message = "reader_users get the dashboard role too."
  }
}

run "okta_sign_in" {
  command = plan

  variables {
    dashboard_sign_in = { console_origin = "https://app.example.com", external = {
      provider = "okta", issuer = "https://acme.okta.com/oauth2/aus1/", audience = "snowflake"
    } }
  }

  assert {
    condition = (snowflake_external_oauth_integration.dashboards[0].external_oauth_type == "OKTA"
      && contains(snowflake_external_oauth_integration.dashboards[0].external_oauth_jws_keys_url, "https://acme.okta.com/oauth2/aus1/v1/keys")
    && contains(snowflake_external_oauth_integration.dashboards[0].external_oauth_token_user_mapping_claim, "sub"))
    error_message = "Okta: keys under the issuer, sub mapped to the login name."
  }
}

run "both_methods" {
  command = plan

  variables {
    dashboard_sign_in = { console_origin = "https://app.example.com", snowflake = { refresh_token_validity = 172800 }, external = {
      provider = "custom", issuer = "https://idp.example.com", jws_keys_url = "https://idp.example.com/keys", audience = "snowflake"
    } }
  }

  assert {
    condition = (length(snowflake_oauth_integration_for_custom_clients.dashboards) == 1 && length(snowflake_external_oauth_integration.dashboards) == 1
    && snowflake_oauth_integration_for_custom_clients.dashboards[0].oauth_refresh_token_validity == 172800)
    error_message = "Both integrations at once."
  }
}

run "rejects_an_origin_with_a_path" {
  command = plan
  variables {
    dashboard_sign_in = { console_origin = "https://app.example.com/settings", snowflake = {} }
  }
  expect_failures = [var.dashboard_sign_in]
}

run "rejects_plain_http" {
  command = plan
  variables {
    dashboard_sign_in = { console_origin = "http://app.example.com", snowflake = {} }
  }
  expect_failures = [var.dashboard_sign_in]
}

run "rejects_the_default_port" {
  command = plan
  variables {
    dashboard_sign_in = { console_origin = "https://app.example.com:443", snowflake = {} }
  }
  expect_failures = [var.dashboard_sign_in]
}

run "rejects_a_zero_padded_port" {
  command = plan
  variables {
    dashboard_sign_in = { console_origin = "https://app.example.com:08443", snowflake = {} }
  }
  expect_failures = [var.dashboard_sign_in]
}

run "accepts_another_port" {
  command = plan
  variables {
    dashboard_sign_in = { console_origin = "https://app.example.com:8443", snowflake = {} }
  }
  assert {
    condition     = snowflake_oauth_integration_for_custom_clients.dashboards[0].oauth_redirect_uri == "https://app.example.com:8443/lakehouse/snowflake-redirect.html"
    error_message = "A non-default port is part of the origin."
  }
}

run "rejects_no_method" {
  command = plan
  variables {
    dashboard_sign_in = { console_origin = "https://app.example.com" }
  }
  expect_failures = [var.dashboard_sign_in]
}

run "rejects_entra_without_tenant" {
  command = plan
  variables {
    dashboard_sign_in = { console_origin = "https://app.example.com", external = { provider = "entra", audience = "api://x" } }
  }
  expect_failures = [var.dashboard_sign_in]
}

run "rejects_custom_without_keys" {
  command = plan
  variables {
    dashboard_sign_in = { console_origin = "https://app.example.com", external = { provider = "custom", issuer = "https://idp.example.com", audience = "x" } }
  }
  expect_failures = [var.dashboard_sign_in]
}

run "rejects_an_unknown_provider" {
  command = plan
  variables {
    dashboard_sign_in = { console_origin = "https://app.example.com", external = { provider = "cognito", issuer = "https://x", audience = "x" } }
  }
  expect_failures = [var.dashboard_sign_in]
}

run "rejects_a_short_refresh" {
  command = plan
  variables {
    dashboard_sign_in = { console_origin = "https://app.example.com", snowflake = { refresh_token_validity = 86399 } }
  }
  expect_failures = [var.dashboard_sign_in]
}
