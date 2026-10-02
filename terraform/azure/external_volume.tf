# The tenant Snowflake's generated service principal will request admin consent against --
# read, not hardcoded, so customers never need to look up their own tenant id.
data "azuread_client_config" "current" {}

# Module-owned, same as the Iceberg storage account/container (storage.tf) -- unlike the
# customer's existing logs account, Snowflake has no pre-existing database to reuse either.
resource "snowflake_database" "lakehouse" {
  name = local.database_name
}

resource "snowflake_schema" "lakehouse" {
  database = snowflake_database.lakehouse.name
  name     = local.schema_name
}

# Creating this resource is what makes Snowflake generate the service principal + admin-consent
# URL role_assignments.tf depends on -- Snowflake can't access the container (storage.tf) until
# that consent is granted and the corresponding role assignments exist.
resource "snowflake_external_volume" "lakehouse" {
  name = local.database_name

  storage_location {
    storage_location_name = azurerm_storage_container.iceberg.name
    storage_provider      = "AZURE"
    storage_base_url      = "azure://${azurerm_storage_account.iceberg.name}.blob.core.windows.net/${azurerm_storage_container.iceberg.name}/"
    azure_tenant_id       = data.azuread_client_config.current.tenant_id
  }
}
