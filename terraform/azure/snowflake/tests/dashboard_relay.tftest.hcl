# The dashboards' sign-in on Azure (dashboard_sign_in.tf, dashboard_relay.tf), with mocked providers
# (no Azure or Snowflake access; every run is a plan):
#
#   cd terraform/azure/snowflake && terraform init -backend=false && terraform test
#
# Needs Terraform >= 1.7 (mock providers).

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = { subscription_id = "00000000-0000-0000-0000-000000000001", tenant_id = "00000000-0000-0000-0000-000000000002" }
  }
  mock_data "azurerm_resources" {
    defaults = { resources = [{ location = "eastus2", name = "acmelogs", id = "/x", type = "Microsoft.Storage/storageAccounts", tags = {}, resource_group_name = "rg" }] }
  }
}
mock_provider "azuread" {}
mock_provider "time" {}

mock_provider "snowflake" {
  mock_resource "snowflake_account_role" {
    defaults = { fully_qualified_name = "\"traceforce_lakehouse_reader\"" }
  }
  mock_resource "snowflake_oauth_integration_for_custom_clients" {
    defaults = { fully_qualified_name = "\"Lakehouse\"" }
  }
  mock_resource "snowflake_database" {
    defaults = { fully_qualified_name = "\"traceforce_lakehouse\"" }
  }
  mock_resource "snowflake_schema" {
    defaults = { fully_qualified_name = "\"traceforce_lakehouse\".\"traceforce\"" }
  }
  mock_resource "snowflake_warehouse" {
    defaults = { fully_qualified_name = "\"traceforce_lakehouse\"" }
  }
}

variables {
  logs_storage_account_name    = "acmelogs"
  logs_resource_group_name     = "rg-logs"
  logs_container_name          = "logs"
  iceberg_storage_account_name = "acmeiceberg"
}

run "dashboard_relay" {
  command = plan

  variables {
    dashboard_sign_in = { console_origin = "https://app.example.com/", snowflake = {} }
  }
  override_resource {
    target          = snowflake_execute.dashboards_lookup
    override_during = plan
    values          = { query_results = [{ ORG = "ACME", ACCOUNT = "PROD_US", CLIENT_ID = "client+id/1=" }] }
  }
  override_resource {
    target          = snowflake_account_role.reader
    override_during = plan
    values          = { fully_qualified_name = "\"traceforce_lakehouse_reader\"" }
  }

  assert {
    condition = (azurerm_function_app_flex_consumption.relay[0].site_config[0].cors[0].allowed_origins == toset(["https://app.example.com"])
      && azurerm_function_app_flex_consumption.relay[0].runtime_name == "node" && azurerm_function_app_flex_consumption.relay[0].https_only
    && azurerm_function_app_flex_consumption.relay[0].storage_authentication_type == "UserAssignedIdentity")
    error_message = "A Node Flex Consumption Function, HTTPS only, CORS for the console's origin, reading its storage with its identity."
  }
  assert {
    condition = (azurerm_function_app_flex_consumption.relay[0].app_settings["TOKEN_URL"] == "https://acme-prod-us.snowflakecomputing.com/oauth/token-request"
      && azurerm_function_app_flex_consumption.relay[0].app_settings["CLIENT_ID"] == "client+id/1="
    && azurerm_function_app_flex_consumption.relay[0].app_settings["ALLOWED_ORIGIN"] == "https://app.example.com")
    error_message = "The relay forwards to this account's token endpoint, for the dashboards' client, from the console's origin."
  }
  assert {
    condition     = azurerm_storage_account.relay[0].name != var.iceberg_storage_account_name && azurerm_storage_account.relay[0].name != var.logs_storage_account_name && length(azurerm_storage_account.relay[0].name) <= 24
    error_message = "The Function gets a storage account of its own (never the logs or Iceberg account), within Azure's 24-character limit."
  }
  assert {
    condition     = output.dashboard_settings.snowflake.scope == "refresh_token session:role:\"traceforce_lakehouse_reader\"" && output.dashboard_settings.role == "traceforce_lakehouse_reader"
    error_message = "Same sign-in settings as on AWS."
  }
}

run "no_relay_for_an_identity_provider" {
  command = plan
  variables {
    dashboard_sign_in = { console_origin = "https://app.example.com", external = {
      provider = "entra", tenant_id = "11111111-2222-3333-4444-555555555555", audience = "api://traceforce-lakehouse"
    } }
  }

  assert {
    condition     = length(azurerm_function_app_flex_consumption.relay) == 0 && length(azurerm_storage_account.relay) == 0 && length(snowflake_external_oauth_integration.dashboards) == 1
    error_message = "Signing in through the company's identity provider needs no relay."
  }
}

run "no_relay_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_function_app_flex_consumption.relay) == 0 && output.dashboard_settings == null
    error_message = "Without dashboard_sign_in there is no relay and no settings output."
  }
}
