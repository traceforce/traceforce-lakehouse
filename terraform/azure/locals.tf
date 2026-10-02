locals {
  # Fixed names: the skill, docs and Snowflake examples all assume them. Snowflake's unquoted
  # identifiers don't allow hyphens, so the database name uses an underscore even though the
  # Iceberg container (storage.tf) is hyphenated like the AWS/GCP buckets.
  name          = "traceforce-lakehouse"
  database_name = "traceforce_lakehouse"
  schema_name   = "traceforce"

  # The raw landing container's own root URL (not the new Iceberg container) -- the credentialed
  # base a Snowflake stage authenticates against. Individual external tables append their own
  # relative path (telemetry/ or _traceforce/lakehouse/exports/<table>/) below this.
  container_root = "azure://${data.azurerm_storage_account.logs.name}.blob.core.windows.net/${var.logs_container_name}/"

  # Where scout's OTel exporter writes activity objects -- Hive key=value for agent and upload day (UTC):
  #   <container_root>/<prefix>/telemetry/agent=<AGENT_IDENTITY_*>/dt=<YYYYMMDD>/<serial>/<email>[_<org>]/<session>/<ts>_<uuid>_logs|traces.json.gz
  prefix_slash = var.logs_prefix == "" ? "" : "${var.logs_prefix}/"
  raw_root     = "${local.container_root}${local.prefix_slash}telemetry/"
  # TraceForce's daily metadata snapshots land under this subtree of the raw landing container.
  derived_root = "${local.container_root}${local.prefix_slash}_traceforce/lakehouse/"
  exports_root = "${local.derived_root}exports/"
}
