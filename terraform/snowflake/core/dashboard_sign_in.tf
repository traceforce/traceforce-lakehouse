# Optional sign-in for the TraceForce UI dashboards. The viewer's browser queries Snowflake's SQL API
# directly, as the viewer, with an OAuth token limited to the reader role's access. TraceForce never holds the
# token or sees a row. Two ways to get the token, either or both:
#
#   snowflake: Snowflake's own sign-in (its login page: password, MFA or the account's SSO). A public
#              PKCE client, so no secret. Browsers can't read Snowflake's token endpoint (no CORS),
#              so the calling module puts a relay in front of it (dashboard_relay.tf).
#   external:  the company's identity provider (Entra ID, Okta or another OAuth server), through
#              Snowflake External OAuth. Everything happens in the browser.
#
# Each Snowflake user that views the dashboards needs the reader role (snowflake) or
# TRACEFORCE_LAKEHOUSE_DASHBOARD (external), both granted to reader_users, and for external a login name
# matching the token's user claim.

locals {
  sign_in          = var.dashboard_sign_in
  snowflake_signin = try(local.sign_in.snowflake, null)
  external_signin  = try(local.sign_in.external, null)

  # Where the UI's sign-in pop-up returns: a page of its own, as for the Databricks dashboards' MSAL
  # sign-in (lakehouse/msal-redirect.html).
  dashboard_redirect_uri = local.sign_in == null ? null : "${trimsuffix(local.sign_in.console_origin, "/")}/lakehouse/snowflake-redirect.html"

  external_provider = try(local.external_signin.provider, null)
  # Entra ID: issuer and keys from the tenant (the v1 issuer: Entra issues v1 access tokens unless the
  # resource app sets accessTokenAcceptedVersion to 2). Okta: keys under a custom authorization
  # server's issuer (https://<org>.okta.com/oauth2/<id>/v1/keys).
  external_issuer = local.external_signin == null ? null : (
    local.external_provider == "entra" ? "https://sts.windows.net/${local.external_signin.tenant_id}/" : local.external_signin.issuer
  )
  external_jws_keys_url = local.external_signin == null ? null : coalesce(
    local.external_signin.jws_keys_url,
    local.external_provider == "entra" ? "https://login.microsoftonline.com/${local.external_signin.tenant_id}/discovery/v2.0/keys" : null,
    local.external_provider == "okta" ? "${trimsuffix(coalesce(local.external_signin.issuer, "-"), "/")}/v1/keys" : null,
  )
  external_user_claim = local.external_signin == null ? null : coalesce(
    local.external_signin.user_claim, local.external_provider == "entra" ? "upn" : "sub",
  )
}

resource "snowflake_oauth_integration_for_custom_clients" "dashboards" {
  count = local.snowflake_signin == null ? 0 : 1

  # Viewers see this name on Snowflake's sign-in page: "Sign in to Snowflake to continue to Lakehouse".
  # The provider quotes it, so Snowflake keeps the case.
  name               = "Lakehouse"
  comment            = "TraceForce UI dashboards: viewers sign in with Snowflake and query as the reader role."
  oauth_client_type  = "PUBLIC"
  oauth_redirect_uri = local.dashboard_redirect_uri
  oauth_enforce_pkce = "true"
  # Secondary roles off, so the session holds the reader role only; that is also what lets the
  # allowed roles list (dashboards_roles) limit the token to it.
  oauth_use_secondary_roles    = "NONE"
  oauth_issue_refresh_tokens   = "true"
  oauth_refresh_token_validity = local.snowflake_signin.refresh_token_validity
  # Created disabled: until dashboards_roles sets the list, it is empty, which allows any role but
  # ACCOUNTADMIN, ORGADMIN and SECURITYADMIN. dashboards_roles enables it.
  enabled = "false"

  lifecycle {
    ignore_changes = [allowed_roles_list, enabled] # set by dashboards_roles
  }
}

# Only the reader role may be used with a dashboards token. Set with SQL: the list must name the
# lowercase role quoted, '"traceforce_lakehouse_reader"', and the provider writes it unquoted, which
# Snowflake rejects. The same statement enables the integration, so it is never enabled without the
# list. Reruns when the integration is replaced; a plan fails if the list or the switch was changed
# outside Terraform (fix: terraform apply -replace on this resource).
resource "snowflake_execute" "dashboards_roles" {
  count = local.snowflake_signin == null ? 0 : 1

  execute = "ALTER SECURITY INTEGRATION ${snowflake_oauth_integration_for_custom_clients.dashboards[0].fully_qualified_name} SET ALLOWED_ROLES_LIST = ('${snowflake_account_role.reader.fully_qualified_name}') ENABLED = TRUE"
  revert  = "SELECT 1" # the integration's own destroy removes it
  query   = "DESCRIBE SECURITY INTEGRATION ${snowflake_oauth_integration_for_custom_clients.dashboards[0].fully_qualified_name}"

  lifecycle {
    replace_triggered_by = [snowflake_oauth_integration_for_custom_clients.dashboards[0]]
    postcondition {
      condition = alltrue([
        contains([for r in self.query_results : lookup(r, "property_value", "") if lookup(r, "property", "") == "ALLOWED_ROLES_LIST"], snowflake_account_role.reader.name),
        length([for r in self.query_results : r if lookup(r, "property", "") == "ALLOWED_ROLES_LIST" && lookup(r, "property_value", "") != snowflake_account_role.reader.name]) == 0,
        contains([for r in self.query_results : lookup(r, "property_value", "") if lookup(r, "property", "") == "ENABLED"], "true"),
      ])
      error_message = "The Lakehouse integration's ALLOWED_ROLES_LIST isn't exactly the reader role, or it is disabled (changed outside Terraform?). Restore it with terraform apply -replace on this resource."
    }
  }
}

# The account's URL and the client ID the browser sends, read with SQL: the account from the
# session (no preview data source, so callers' provider blocks need nothing new), the client ID from
# SYSTEM$SHOW_OAUTH_CLIENT_SECRETS (DESCRIBE INTEGRATION doesn't show it). Only the ID column is
# read, so the state never holds a secret. Reruns when the integration is replaced (new client ID).
resource "snowflake_execute" "dashboards_lookup" {
  count = local.sign_in == null ? 0 : 1

  execute = "SELECT 1"
  revert  = "SELECT 1"
  query = join(" ", [
    "SELECT CURRENT_ORGANIZATION_NAME() AS ORG, CURRENT_ACCOUNT_NAME() AS ACCOUNT,",
    local.snowflake_signin == null ? "NULL" : "PARSE_JSON(SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('${snowflake_oauth_integration_for_custom_clients.dashboards[0].name}')):OAUTH_CLIENT_ID::STRING",
    "AS CLIENT_ID",
    # The integration's creation time: a replaced integration changes the query, so it reruns.
    "/* ${try(snowflake_oauth_integration_for_custom_clients.dashboards[0].show_output[0].created_on, "")} */",
  ])

  lifecycle {
    postcondition {
      condition     = try(self.query_results[0]["ACCOUNT"], "") != "" && (local.snowflake_signin == null || try(self.query_results[0]["CLIENT_ID"], "") != "")
      error_message = "Couldn't read the account name or the dashboards' OAuth client ID (SYSTEM$SHOW_OAUTH_CLIENT_SECRETS needs the integration's owner, e.g. ACCOUNTADMIN, which Terraform uses)."
    }
  }
}

locals {
  dashboards_lookup = try(snowflake_execute.dashboards_lookup[0].query_results[0], {})
  # https://<org>-<account>.snowflakecomputing.com; an underscore in the account name becomes a
  # hyphen in the host name.
  dashboard_account_url = local.sign_in == null ? null : lower("https://${try(local.dashboards_lookup["ORG"], "")}-${replace(try(local.dashboards_lookup["ACCOUNT"], ""), "_", "-")}.snowflakecomputing.com")
}

# Company sign-in can't name the reader role: its stored name is lowercase, an identity provider's
# scope can't carry the quotes (Entra rejects them), and Snowflake reads an unquoted name as uppercase.
# So it gets an uppercase role of its own that inherits the reader role and nothing else. Not the
# "any role" mode instead: that activates the viewer's default secondary roles. Live-tested with Entra:
# this role only, no secondary roles, reads allowed, writes and other roles refused.
resource "snowflake_account_role" "dashboard" {
  count   = local.external_signin == null ? 0 : 1
  name    = "TRACEFORCE_LAKEHOUSE_DASHBOARD"
  comment = "TraceForce UI dashboards, company sign-in: the reader role's access, nothing more."
}

resource "snowflake_grant_account_role" "dashboard_reader" {
  count            = local.external_signin == null ? 0 : 1
  role_name        = snowflake_account_role.reader.fully_qualified_name
  parent_role_name = snowflake_account_role.dashboard[0].name # uppercase: the plain name is exact
}

# reader_users can use the dashboards with company sign-in too.
resource "snowflake_grant_account_role" "dashboard_users" {
  for_each  = local.external_signin == null ? toset([]) : toset(var.reader_users)
  role_name = snowflake_account_role.dashboard[0].name
  user_name = each.value
}

resource "snowflake_external_oauth_integration" "dashboards" {
  count = local.external_signin == null ? 0 : 1

  name                                            = "traceforce_lakehouse_dashboards_idp"
  comment                                         = "TraceForce UI dashboards: viewers sign in with the company's identity provider and query as TRACEFORCE_LAKEHOUSE_DASHBOARD."
  enabled                                         = true
  external_oauth_type                             = { entra = "AZURE", okta = "OKTA", custom = "CUSTOM" }[local.external_provider]
  external_oauth_issuer                           = local.external_issuer
  external_oauth_jws_keys_url                     = [local.external_jws_keys_url]
  external_oauth_audience_list                    = [local.external_signin.audience]
  external_oauth_token_user_mapping_claim         = [local.external_user_claim]
  external_oauth_snowflake_user_mapping_attribute = local.external_signin.snowflake_user_attribute
  # The token's scope names the role (session:scope:TRACEFORCE_LAKEHOUSE_DASHBOARD on Entra); only that
  # role is accepted. Set with the integration in one statement (an uppercase name the provider can write),
  # so it is never enabled without the list.
  external_oauth_allowed_roles_list = [snowflake_account_role.dashboard[0].name]
  external_oauth_any_role_mode      = "DISABLE"
}
