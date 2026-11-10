# run_as.tf, when the account ID lookup finds no ID (see run_as.tftest.hcl for how to run).

# Azure IDs are validated by the azurerm provider, so the mocks give well-formed ones.
mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = { subscription_id = "00000000-0000-4000-8000-000000000000", tenant_id = "00000000-0000-4000-8000-000000000001" }
  }
  mock_resource "azurerm_databricks_access_connector" {
    defaults = { id = "/subscriptions/00000000-0000-4000-8000-000000000000/resourceGroups/logs-rg/providers/Microsoft.Databricks/accessConnectors/connector" }
  }
  mock_resource "azurerm_storage_account" {
    defaults = { id = "/subscriptions/00000000-0000-4000-8000-000000000000/resourceGroups/logs-rg/providers/Microsoft.Storage/storageAccounts/icebergaccount" }
  }
  mock_resource "azurerm_storage_container" {
    defaults = { id = "/subscriptions/00000000-0000-4000-8000-000000000000/resourceGroups/logs-rg/providers/Microsoft.Storage/storageAccounts/icebergaccount/blobServices/default/containers/traceforce-lakehouse" }
  }
  override_data {
    target = data.azurerm_resources.logs
    values = { resources = [{ name = "logsaccount", location = "westus3", type = "Microsoft.Storage/storageAccounts" }] }
  }
}

mock_provider "azapi" {
  override_resource {
    target = azapi_resource.workspace
    values = { output = { properties = { workspaceUrl = "adb-1.1.azuredatabricks.net" } } }
  }
}

# The run log's creation time (tables.tf) goes through formatdate, so it must be a real timestamp.
mock_provider "time" {
  mock_resource "time_static" {
    defaults = { rfc3339 = "2026-01-01T00:00:00Z" }
  }
}

mock_provider "databricks" {
  mock_resource "databricks_sql_endpoint" {
    defaults = { odbc_params = [{ hostname = "adb-1.1.azuredatabricks.net", path = "/sql/1.0/warehouses/0000", port = 443, protocol = "https" }] }
  }
  override_data {
    target = data.databricks_current_user.deployer
    values = { user_name = "deployer@acme.com", acl_principal_id = "users/deployer@acme.com" }
  }
  override_data {
    target = data.databricks_workspace_iam_service_principal_v2.ingest
    values = { account_id = "" }
  }
}

variables {
  logs_storage_account_name    = "logsaccount"
  logs_resource_group_name     = "logs-rg"
  logs_container_name          = "logs"
  iceberg_storage_account_name = "icebergaccount"
  databricks_workspace_name    = "lakehouse"
}

# Unset, and the lookup returns no ID: the rule set's check asks for databricks_account_id.
# Apply: on a first deploy the lookup waits for the new service principal, so the check runs then.
run "empty_lookup_fails" {
  expect_failures = [databricks_access_control_rule_set.ingest]
}

# Set, it doesn't depend on the lookup.
run "account_id_set_needs_no_lookup" {
  variables {
    databricks_account_id = "11111111-1111-4111-8111-111111111111"
  }
}
