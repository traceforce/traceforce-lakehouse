# The lakehouse catalog (unity_catalog.tf): isolated and bound read-write to the module's own
# workspace, whose ID is the number in its URL (see run_as.tftest.hcl for how to run).

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
    values = { account_id = "11111111-1111-4111-8111-111111111111" }
  }
}

variables {
  logs_storage_account_name    = "logsaccount"
  logs_resource_group_name     = "logs-rg"
  logs_container_name          = "logs"
  iceberg_storage_account_name = "icebergaccount"
  databricks_workspace_name    = "lakehouse"
}

run "catalog_bound_to_own_workspace" {
  command = apply # the workspace URL is known only after apply
  assert {
    condition     = databricks_catalog.lakehouse.isolation_mode == "ISOLATED"
    error_message = "isolation_mode is ${databricks_catalog.lakehouse.isolation_mode}"
  }
  assert {
    condition = (
      databricks_workspace_binding.lakehouse.securable_name == "traceforce_lakehouse" &&
      databricks_workspace_binding.lakehouse.securable_type == "catalog" &&
      databricks_workspace_binding.lakehouse.workspace_id == 1 &&
      databricks_workspace_binding.lakehouse.binding_type == "BINDING_TYPE_READ_WRITE"
    )
    error_message = "binding is ${databricks_workspace_binding.lakehouse.securable_type} ${databricks_workspace_binding.lakehouse.securable_name} to workspace ${databricks_workspace_binding.lakehouse.workspace_id}, ${databricks_workspace_binding.lakehouse.binding_type}"
  }
}
