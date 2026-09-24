data "google_project" "this" {}

# The logs bucket, read so residency is explicit and the module fails fast if the location is wrong.
data "google_storage_bucket" "logs" {
  name = var.logs_bucket
}

locals {
  project = data.google_project.this.project_id

  # BigQuery must co-locate with the logs bucket, so the location IS the bucket's own -- no input
  # needed. GCS returns it uppercase (US, US-EAST1); BigQuery wants multi-regions uppercase (US)
  # and regions lowercase (us-east1), so lowercase only when it is a region (contains a hyphen).
  bq_location = strcontains(data.google_storage_bucket.logs.location, "-") ? lower(data.google_storage_bucket.logs.location) : data.google_storage_bucket.logs.location

  # Where scout's OTel exporter writes activity objects -- Hive key=value for agent and upload day (UTC):
  #   gs://<bucket>/<prefix>/telemetry/agent=<AGENT_IDENTITY_*>/dt=<YYYYMMDD>/<serial>/<email>[_<org>]/<session>/<ts>_<uuid>_logs|traces.json.gz
  prefix_slash = var.logs_prefix == "" ? "" : "${var.logs_prefix}/"
  raw_root     = "gs://${var.logs_bucket}/${local.prefix_slash}telemetry/"
  # TraceForce's daily metadata snapshots land under this subtree in the customer's logs bucket.
  derived_root = "gs://${var.logs_bucket}/${local.prefix_slash}_traceforce/lakehouse/"
  exports_root = "${local.derived_root}exports/"
  # The managed Iceberg data lives in a module-owned bucket (see bucket.tf), never the logs bucket.
  iceberg_root = "gs://${google_storage_bucket.iceberg.name}/iceberg/"

  name = "traceforce-lakehouse"

  # Postgres/Iceberg type -> BigQuery type. JSON-bearing columns are already string.
  bq_type = {
    string    = "STRING"
    int       = "INTEGER"
    long      = "INTEGER"
    double    = "FLOAT"
    boolean   = "BOOLEAN"
    timestamp = "TIMESTAMP"
  }

  # agent_events schema from the shared ../schema module. JSON-bearing columns (attrs_json,
  # resource_json, content_*, tool_args/result) are STRING here because managed Iceberg forbids
  # the JSON type.
  agent_events_schema = module.schema.agent_events

  # 18 metadata mirror tables from the shared ../schema module.
  export_tables = module.schema.export_tables

  # "name:type" -> { name, type }
  export_columns = {
    for t, cols in local.export_tables : t => [
      for c in cols : { name = split(":", c)[0], type = split(":", c)[1] }
    ]
  }

  # biglake_configuration.connection_id wants project.location.connection (location lowercased).
  connection_ref = "${local.project}.${lower(local.bq_location)}.${google_bigquery_connection.gcs.connection_id}"

  # Rendered ingest SQL (uses the validated template + the two JS routines).
  ingest_sql = templatefile("${path.module}/sql/ingest_agent_events.sql.tftpl", {
    target          = "${local.project}.${var.dataset_id}.agent_events"
    raw             = "${local.project}.${var.dataset_id}.${google_bigquery_table.raw_telemetry.table_id}"
    lookback_days   = var.lookback_days
    dataset         = "${local.project}.${var.dataset_id}"
    agent_type_case = join(" ", [for k, v in module.schema.agent_identities : "WHEN '${k}' THEN ${v}"])
    cols            = join(", ", [for c in local.agent_events_schema : c.name])
  })

  # Rendered mirror SQL: one guarded atomic MERGE per table, concatenated into one daily script.
  # NOTE: this runs as ONE multi-statement script, so a runtime error on any table aborts every
  # table after it that run (unlike AWS's Step Functions Map, which isolates per-table). Each MERGE
  # is a full idempotent upsert, so the next run after the bad table is fixed catches the rest up;
  # a failed run is visible in the BigQuery scheduled-query run history.
  mirror_sql = join("\n", [
    for t, cols in local.export_columns : templatefile("${path.module}/sql/mirror_export.sql.tftpl", {
      target      = "${local.project}.${var.dataset_id}.${t}"
      source      = "${local.project}.${var.dataset_id}.export_${t}"
      cols        = join(", ", [for c in cols : c.name])
      update_set  = join(", ", [for c in cols : "${c.name} = s.${c.name}" if c.name != "id"])
      insert_vals = join(", ", [for c in cols : "s.${c.name}"])
    })
  ])
}
