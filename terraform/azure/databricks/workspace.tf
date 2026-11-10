# The Databricks workspace the lakehouse runs in, created by the module so the customer needs no
# prepared workspace. A serverless workspace (computeMode = "Serverless"): serverless compute only,
# which is all the module uses, with no customer-side VNet, NAT gateway or managed resource group.
# Created through azapi because azurerm_databricks_workspace has no compute mode setting.
resource "azapi_resource" "workspace" {
  type      = "Microsoft.Databricks/workspaces@2026-01-01"
  name      = var.databricks_workspace_name
  parent_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.logs_resource_group_name}"
  # Same region as the logs account: no cross-region egress, same residency.
  location = local.logs_account_location
  tags     = local.tags
  body = {
    sku        = { name = "premium" } # Unity Catalog needs Premium
    properties = { computeMode = "Serverless" }
  }
  response_export_values = ["properties.workspaceUrl"]

  lifecycle {
    precondition {
      condition     = length(data.azurerm_resources.logs.resources) == 1
      error_message = "Storage account ${var.logs_storage_account_name} was not found in resource group ${var.logs_resource_group_name}, or the deploying identity cannot read it."
    }
  }
}
