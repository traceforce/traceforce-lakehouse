locals {
  # Fixed names: the skill, docs and examples all assume them. The catalog name uses an underscore
  # to match the Snowflake database name.
  name         = "traceforce-lakehouse" # the Iceberg container
  catalog_name = var.catalog_name
  schema_name  = "traceforce"

  # On every resource that takes tags, so usage and budgets can be filtered to this module.
  tags = { traceforce = "lakehouse" }

  # Composed from the inputs rather than read from azurerm_resources, as in the Snowflake module.
  logs_account_id       = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.logs_resource_group_name}/providers/Microsoft.Storage/storageAccounts/${var.logs_storage_account_name}"
  logs_account_location = try(data.azurerm_resources.logs.resources[0].location, "")

  # The raw landing container's root in the logs account, over the ADLS Gen2 (dfs) endpoint that
  # Unity Catalog external locations use.
  container_root = "abfss://${var.logs_container_name}@${var.logs_storage_account_name}.dfs.core.windows.net/"

  # Where scout's OTel exporter writes activity objects -- Hive key=value for agent and upload day (UTC):
  #   <container_root>/<prefix>/telemetry/agent=<AGENT_IDENTITY_*>/dt=<YYYYMMDD>/<serial>/<email>[_<org>]/<session>/<ts>_<uuid>_logs|traces.json.gz
  # TraceForce's daily metadata snapshots land under <container_root>/<prefix>/_traceforce/lakehouse/exports/.
  # render_sql (ingest.tf) builds both paths from container_root + prefix_slash.
  prefix_slash = var.logs_prefix == "" ? "" : "${var.logs_prefix}/"
  exports_root = "${local.container_root}${local.prefix_slash}_traceforce/lakehouse/exports/"

  # Tables, from terraform/schema/columns.json: agent_events, and one mirror per export table.
  agent_events_columns = module.schema.agent_events
  export_tables        = module.schema.export_tables
}
