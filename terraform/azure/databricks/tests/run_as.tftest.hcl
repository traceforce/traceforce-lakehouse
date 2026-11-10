# The service principal's role rule set (run_as.tf): who gets the roles, and the two checks on the
# account ID. A mistake here locks deployers out of the principal, so it's tested without Azure or
# Databricks: every provider is mocked and each run applies to an in-memory state.
#
#   cd terraform/azure/databricks && terraform init -backend=false && terraform test
#
# Needs Terraform >= 1.7 (mock providers); the module itself still needs only 1.5.

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

# Each kind gets its prefix; group names kept exactly (case-sensitive); the identity running apply
# always included.
run "deployers_map_to_principals" {
  variables {
    additional_deployer_user_names              = ["jdoe@acme.com"]
    additional_deployer_group_names             = ["Platform-Team"]
    additional_deployer_service_principal_names = ["abcdef01-2345-4678-9abc-def012345678"]
  }

  assert {
    condition = toset(local.deployer_principals) == toset([
      "users/deployer@acme.com",
      "users/jdoe@acme.com",
      "groups/Platform-Team",
      "servicePrincipals/abcdef01-2345-4678-9abc-def012345678",
    ])
    error_message = "deployer_principals is ${jsonencode(local.deployer_principals)}"
  }
}

# Unset: the ID comes from the lookup, is stored, and names the rule set.
run "account_id_from_lookup" {
  assert {
    condition     = terraform_data.databricks_account_id.output == "11111111-1111-4111-8111-111111111111"
    error_message = "stored account ID is ${jsonencode(terraform_data.databricks_account_id.output)}"
  }
  assert {
    condition     = startswith(databricks_access_control_rule_set.ingest.name, "accounts/11111111-1111-4111-8111-111111111111/servicePrincipals/")
    error_message = "rule set name is ${databricks_access_control_rule_set.ingest.name}"
  }
}

# Setting the same ID that was stored changes nothing.
run "same_account_id_set" {
  variables {
    databricks_account_id = "11111111-1111-4111-8111-111111111111"
  }
}

# A different ID would rename, and so replace, the rule set: it must fail at plan.
run "changed_account_id_fails" {
  command = plan
  variables {
    databricks_account_id = "22222222-2222-4222-8222-222222222222"
  }
  expect_failures = [databricks_access_control_rule_set.ingest]
}

# User names and application IDs must be in lowercase (variables.tf): refused at plan.
run "deployer_user_capitals_refused" {
  command = plan
  variables {
    additional_deployer_user_names = ["JDoe@acme.com"]
  }
  expect_failures = [var.additional_deployer_user_names]
}

run "deployer_service_principal_capitals_refused" {
  command = plan
  variables {
    additional_deployer_service_principal_names = ["ABCDEF01-2345-4678-9ABC-DEF012345678"]
  }
  expect_failures = [var.additional_deployer_service_principal_names]
}

run "reader_user_capitals_refused" {
  command = plan
  variables {
    reader_user_names = ["JDoe@acme.com"]
  }
  expect_failures = [var.reader_user_names]
}

run "reader_service_principal_capitals_refused" {
  command = plan
  variables {
    reader_service_principal_names = ["ABCDEF01-2345-4678-9ABC-DEF012345678"]
  }
  expect_failures = [var.reader_service_principal_names]
}

# Readers' CAN_VIEW on the jobs: off by default, on with reader_can_view_jobs = true (the owner
# entry stays either way).
run "readers_view_jobs_when_enabled" {
  command = plan
  variables {
    reader_user_names    = ["reader@acme.com"]
    reader_can_view_jobs = true
  }
  override_data {
    target = data.databricks_user.reader["reader@acme.com"]
    values = { user_name = "reader@acme.com" }
  }
  assert {
    condition     = length(databricks_permissions.job["ingest"].access_control) == 2 && length([for a in databricks_permissions.job["ingest"].access_control : a if a.user_name == "reader@acme.com" && a.permission_level == "CAN_VIEW"]) == 1
    error_message = "ingest job permissions are ${jsonencode(databricks_permissions.job["ingest"].access_control)}"
  }
}

run "readers_jobs_view_off_by_default" {
  command = plan
  variables {
    reader_user_names = ["reader@acme.com"]
  }
  override_data {
    target = data.databricks_user.reader["reader@acme.com"]
    values = { user_name = "reader@acme.com" }
  }
  assert {
    condition     = length(databricks_permissions.job["ingest"].access_control) == 1 && one(databricks_permissions.job["ingest"].access_control).permission_level == "IS_OWNER"
    error_message = "ingest job permissions are ${jsonencode(databricks_permissions.job["ingest"].access_control)}"
  }
  assert {
    condition     = length(databricks_grant.reader_catalog) == 1 && length(databricks_permissions.query_warehouse) == 1
    error_message = "the reader's lakehouse access must stay"
  }
}
