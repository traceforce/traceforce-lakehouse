# The managed identity Unity Catalog uses to reach both storage accounts (the storage credential
# in unity_catalog.tf). Its roles are in role_assignments.tf.
resource "azurerm_databricks_access_connector" "lakehouse" {
  name                = local.name
  resource_group_name = var.logs_resource_group_name
  location            = local.logs_account_location
  tags                = local.tags

  identity {
    type = "SystemAssigned"
  }
}
