# The SQL warehouses (compute.tf): the query warehouse's auto-stop is settable, the ingest one's is
# fixed (see run_as.tftest.hcl for how to run).

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

# Unset: both warehouses stop after one idle minute.
run "auto_stop_default" {
  command = plan
  assert {
    condition     = databricks_sql_endpoint.query.auto_stop_mins == 1 && databricks_sql_endpoint.ingest.auto_stop_mins == 1
    error_message = "auto_stop_mins is query ${databricks_sql_endpoint.query.auto_stop_mins}, ingest ${databricks_sql_endpoint.ingest.auto_stop_mins}"
  }
}

# Set: only the query warehouse changes.
run "query_auto_stop_set" {
  command = plan
  variables {
    query_auto_stop_mins = 10
  }
  assert {
    condition     = databricks_sql_endpoint.query.auto_stop_mins == 10 && databricks_sql_endpoint.ingest.auto_stop_mins == 1
    error_message = "auto_stop_mins is query ${databricks_sql_endpoint.query.auto_stop_mins}, ingest ${databricks_sql_endpoint.ingest.auto_stop_mins}"
  }
}

run "query_auto_stop_zero_refused" {
  command = plan
  variables {
    query_auto_stop_mins = 0
  }
  expect_failures = [var.query_auto_stop_mins]
}
