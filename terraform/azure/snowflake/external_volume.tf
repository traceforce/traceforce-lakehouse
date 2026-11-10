# Read, not hardcoded, so customers never need to look up their own tenant id.
data "azuread_client_config" "current" {}

resource "snowflake_database" "lakehouse" {
  name = local.database_name
}

resource "snowflake_schema" "lakehouse" {
  database = snowflake_database.lakehouse.name
  name     = local.schema_name
}

# Creating this is what makes Snowflake generate the service principal and the admin-consent URL
# that role_assignments.tf depends on.
resource "snowflake_external_volume" "lakehouse" {
  name = local.database_name

  storage_location {
    storage_location_name = azurerm_storage_container.iceberg.name
    storage_provider      = "AZURE"
    storage_base_url      = "azure://${azurerm_storage_account.iceberg.name}.blob.core.windows.net/${azurerm_storage_container.iceberg.name}/"
    azure_tenant_id       = data.azuread_client_config.current.tenant_id
  }
}
