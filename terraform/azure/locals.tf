locals {
  # Fixed names: the skill, docs and Snowflake examples all assume them. The database name uses an
  # underscore because Snowflake's unquoted identifiers reject hyphens.
  name          = "traceforce-lakehouse"
  database_name = "traceforce_lakehouse"
  schema_name   = "traceforce"

  # Composed from the inputs rather than read from azurerm_resources, so an existing deployment's
  # role-assignment scopes do not change.
  logs_account_id       = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.logs_resource_group_name}/providers/Microsoft.Storage/storageAccounts/${var.logs_storage_account_name}"
  logs_account_location = try(data.azurerm_resources.logs.resources[0].location, "")

  # The raw landing container's root in the logs account (not the Iceberg container), which
  # Snowflake stages authenticate against.
  container_root = "azure://${var.logs_storage_account_name}.blob.core.windows.net/${var.logs_container_name}/"

  # Where scout's OTel exporter writes activity objects -- Hive key=value for agent and upload day (UTC):
  #   <container_root>/<prefix>/telemetry/agent=<AGENT_IDENTITY_*>/dt=<YYYYMMDD>/<serial>/<email>[_<org>]/<session>/<ts>_<uuid>_logs|traces.json.gz
  prefix_slash = var.logs_prefix == "" ? "" : "${var.logs_prefix}/"
  raw_root     = "${local.container_root}${local.prefix_slash}telemetry/"
  # TraceForce's daily metadata snapshots land under this subtree of the raw landing container.
  derived_root = "${local.container_root}${local.prefix_slash}_traceforce/lakehouse/"
  exports_root = "${local.derived_root}exports/"
}
