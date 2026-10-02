# The customer's existing logs account, looked up rather than created. azurerm_resources instead
# of azurerm_storage_account: the latter calls ListKeys and writes the account keys into state.
data "azurerm_resources" "logs" {
  name                = var.logs_storage_account_name
  resource_group_name = var.logs_resource_group_name
  type                = "Microsoft.Storage/storageAccounts"
}

data "azurerm_client_config" "current" {}

# Module-owned account for Iceberg table data, never the logs account: a lifecycle rule there
# (common for logs) would also delete table files, and Azure lifecycle filters cannot exclude a
# prefix.
resource "azurerm_storage_account" "iceberg" {
  name                = var.iceberg_storage_account_name
  resource_group_name = var.logs_resource_group_name
  # Same region as the logs account: no cross-region egress, same residency.
  location                 = local.logs_account_location
  account_tier             = "Standard" # starting defaults, not measured; revisit with real usage
  account_replication_type = "LRS"

  # Snowflake reaches this account over the public internet, so network access stays open;
  # anonymous blob access never is.
  public_network_access_enabled   = true
  allow_nested_items_to_be_public = false

  lifecycle {
    precondition {
      condition     = length(data.azurerm_resources.logs.resources) == 1
      error_message = "Storage account ${var.logs_storage_account_name} was not found in resource group ${var.logs_resource_group_name}, or the deploying identity cannot read it."
    }
  }
}

# storage_account_id rather than the deprecated storage_account_name.
resource "azurerm_storage_container" "iceberg" {
  name                  = local.name
  storage_account_id    = azurerm_storage_account.iceberg.id
  container_access_type = "private"
}
