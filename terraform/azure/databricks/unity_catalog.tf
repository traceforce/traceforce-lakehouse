# Unity Catalog objects in the workspace the module creates: the storage credential for the access
# connector, an external location on each storage account, and the catalog and schema the tables
# live in. Names are fixed, like the catalog's: the skill, docs and examples assume them, and they
# are unique within the region's metastore.

# Not read_only: a read-only credential would make every location that uses it read-only, and the
# Iceberg location must be writable. Registering it needs the connector's Reader role on itself.
resource "databricks_storage_credential" "lakehouse" {
  name    = local.catalog_name
  comment = "TraceForce lakehouse: the access connector's managed identity"

  azure_managed_identity {
    access_connector_id = azurerm_databricks_access_connector.lakehouse.id
  }

  depends_on = [time_sleep.raw_read_propagation]
}

# The customer's logs (raw telemetry and the export snapshots), read only: Databricks refuses
# writes here even before Azure would. File events are off: they are on by default for new
# locations, and the connector has no queue or Event Grid roles.
resource "databricks_external_location" "raw" {
  name               = "${local.catalog_name}_raw"
  url                = "${local.container_root}${local.prefix_slash}"
  credential_name    = databricks_storage_credential.lakehouse.name
  read_only          = true
  enable_file_events = false
  comment            = "TraceForce lakehouse: raw telemetry and export snapshots (read only)"

  depends_on = [time_sleep.raw_read_propagation]
}

# The module's Iceberg container, read-write: the catalog's managed storage. force_destroy: dropped
# managed tables are kept for recovery and still count as dependents of this location, so without
# it destroy always fails once any table has existed. Unity Catalog then no longer purges their
# files, but destroy deletes the whole Iceberg storage account anyway.
resource "databricks_external_location" "iceberg" {
  name               = "${local.catalog_name}_iceberg"
  url                = "abfss://${azurerm_storage_container.iceberg.name}@${azurerm_storage_account.iceberg.name}.dfs.core.windows.net/"
  credential_name    = databricks_storage_credential.lakehouse.name
  enable_file_events = false
  force_destroy      = true
  comment            = "TraceForce lakehouse: Iceberg table data"

  depends_on = [time_sleep.iceberg_write_propagation]
}

# Managed tables land in the module's Iceberg account through storage_root, not Databricks default
# storage. Managed Iceberg tables need predictive optimization; set here in case the metastore has
# it off. force_destroy: destroy must drop the catalog even with tables in it (the tables are made
# by SQL, not Terraform). Catalogs live in the account-level metastore and outlive the workspace,
# so a leftover traceforce_lakehouse would block a re-deploy. The customer's raw logs are untouched.
# ISOLATED: other workspaces on the metastore can't see or use the catalog, whatever their grants.
# The provider binds the workspace it runs in right after setting it (and again before deleting).
resource "databricks_catalog" "lakehouse" {
  name                           = local.catalog_name
  storage_root                   = databricks_external_location.iceberg.url
  isolation_mode                 = "ISOLATED"
  enable_predictive_optimization = "ENABLE"
  force_destroy                  = true
  comment                        = "TraceForce lakehouse"
}

# The module's workspace, explicit so the binding is in state.
# The workspace ID is the number in the URL (adb-<id>.<n>.azuredatabricks.net). Everything that
# needs the catalog at destroy (schema, tables, catalog grants) depends on this, so it is removed
# only after them.
resource "databricks_workspace_binding" "lakehouse" {
  securable_name = databricks_catalog.lakehouse.name
  securable_type = "catalog"
  workspace_id   = regex("^adb-([0-9]+)\\.", azapi_resource.workspace.output.properties.workspaceUrl)[0]
  binding_type   = "BINDING_TYPE_READ_WRITE"
}

resource "databricks_schema" "lakehouse" {
  catalog_name  = databricks_catalog.lakehouse.name
  name          = local.schema_name
  force_destroy = true
  comment       = "TraceForce lakehouse: agent_events and the metadata mirrors"

  depends_on = [databricks_workspace_binding.lakehouse]
}
