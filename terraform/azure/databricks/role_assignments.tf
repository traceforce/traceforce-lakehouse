# Roles for the access connector's managed identity. skip_service_principal_aad_check: the
# identity is created in the same apply, and Entra ID replication can lag behind it.
locals {
  connector_principal_id = azurerm_databricks_access_connector.lakehouse.identity[0].principal_id
}

# Registering a storage credential requires the managed identity to hold Reader on the access
# connector itself; without it Unity Catalog rejects the credential.
resource "azurerm_role_assignment" "connector_reader" {
  scope                            = azurerm_databricks_access_connector.lakehouse.id
  role_definition_name             = "Reader"
  principal_id                     = local.connector_principal_id
  skip_service_principal_aad_check = true
}

# Raw logs, read only: data access on the container only. Databricks reads through a user
# delegation key, which is an account-level operation that a container-scoped Reader does not
# cover, so the identity also needs Storage Blob Delegator on the account (it grants no data
# access).
resource "azurerm_role_assignment" "raw_reader" {
  scope                            = "${local.logs_account_id}/blobServices/default/containers/${var.logs_container_name}"
  role_definition_name             = "Storage Blob Data Reader"
  principal_id                     = local.connector_principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "raw_delegator" {
  scope                            = local.logs_account_id
  role_definition_name             = "Storage Blob Delegator"
  principal_id                     = local.connector_principal_id
  skip_service_principal_aad_check = true
}

# RBAC propagation is not instant: a fresh assignment can still 403 for a while. 180s is a
# conservative wait; re-running apply is idempotent if it is not enough.
resource "time_sleep" "raw_read_propagation" {
  depends_on = [azurerm_role_assignment.connector_reader, azurerm_role_assignment.raw_reader, azurerm_role_assignment.raw_delegator]
  triggers = {
    connector_reader_id = azurerm_role_assignment.connector_reader.id
    reader_id           = azurerm_role_assignment.raw_reader.id
    delegator_id        = azurerm_role_assignment.raw_delegator.id
  }
  create_duration = "180s"
}

# Iceberg data, read and write: Contributor on the module's container, and Delegator on its
# account for the user delegation key.
resource "azurerm_role_assignment" "iceberg_contributor" {
  scope                            = azurerm_storage_container.iceberg.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = local.connector_principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "iceberg_delegator" {
  scope                            = azurerm_storage_account.iceberg.id
  role_definition_name             = "Storage Blob Delegator"
  principal_id                     = local.connector_principal_id
  skip_service_principal_aad_check = true
}

resource "time_sleep" "iceberg_write_propagation" {
  depends_on = [azurerm_role_assignment.connector_reader, azurerm_role_assignment.iceberg_contributor, azurerm_role_assignment.iceberg_delegator]
  triggers = {
    connector_reader_id = azurerm_role_assignment.connector_reader.id
    contributor_id      = azurerm_role_assignment.iceberg_contributor.id
    delegator_id        = azurerm_role_assignment.iceberg_delegator.id
  }
  create_duration = "180s"
}
