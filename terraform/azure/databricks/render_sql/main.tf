# Renders the job SQL and the freshness view from the templates in ../sql: text only, no resources
# or providers. Used by ingest.tf and tables.tf, and by the golden test
# (tests/golden/run_databricks.py), so both fill in the templates the same way; only the tables,
# the storage root, lookback_days and the run log's start differ.

variable "agent_events_table" {
  description = "Full name (catalog.schema.table) of the agent_events table the ingest writes."
  type        = string
}

variable "mirror_tables" {
  description = "Export table name -> full name (catalog.schema.table) of its mirror. One mirror script per entry."
  type        = map(string)
}

variable "runs_table" {
  description = "Full name (catalog.schema.table) of the run log every script appends to and the freshness view reads."
  type        = string
}

variable "run_log_since" {
  description = "When the run log was created, UTC, as 'YYYY-MM-DD hh:mm:ss': a table with no logged run counts as stale only once the run log is older than the table's threshold."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$", var.run_log_since))
    error_message = "run_log_since must look like 2026-11-05 04:00:00."
  }
}

variable "logs_root" {
  description = "abfss:// URL of the logs prefix, ending with '/': raw telemetry is under telemetry/, export snapshots under _traceforce/lakehouse/exports/."
  type        = string
  validation {
    condition     = endswith(var.logs_root, "/")
    error_message = "logs_root must end with '/'."
  }
}

variable "lookback_days" {
  description = "How many upload-day folders the ingest reads."
  type        = number
}

module "schema" {
  source = "../../../schema"
}

locals {
  agent_events_columns = module.schema.agent_events
  # { <table> = [{ name, type }] } from columns.json's "name:type" lists.
  export_columns = {
    for t, cols in module.schema.export_tables : t => [
      for c in cols : { name = split(":", c)[0], type = split(":", c)[1] }
    ]
  }
}

output "ingest_sql" {
  description = "The ingest script for agent_events."
  value = templatefile("${path.module}/../sql/ingest_agent_events.sql.tftpl", {
    target        = var.agent_events_table
    runs_table    = var.runs_table
    raw_root      = "${var.logs_root}telemetry/"
    cols          = join(", ", [for c in local.agent_events_columns : "`${c.name}`"])
    select_cols   = join(", ", [for c in local.agent_events_columns : c.name])
    lookback_days = var.lookback_days
  })
}

output "mirror_sql" {
  description = "Export table name -> its mirror script."
  value = {
    for t, target in var.mirror_tables : t => templatefile("${path.module}/../sql/mirror_export.sql.tftpl", {
      target      = target
      table       = t
      runs_table  = var.runs_table
      source_root = "${var.logs_root}_traceforce/lakehouse/exports/${t}/"
      columns     = local.export_columns[t]
    })
  }
}

output "freshness_view_sql" {
  description = "The freshness view's definition (SELECT), one row per table."
  # Without the template's header comment: Databricks drops a view's leading comments when it
  # stores it, so the header would show as a change on every plan.
  value = replace(templatefile("${path.module}/../sql/freshness_view.sql.tftpl", {
    mirror_tables = sort(keys(var.mirror_tables))
    runs_table    = var.runs_table
    run_log_since = var.run_log_since
  }), "/^(--[^\n]*\n)+/", "")
}
