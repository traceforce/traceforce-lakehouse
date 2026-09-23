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

  # Where TraceForce's collector writes activity objects, per agent and upload day (UTC):
  #   gs://<bucket>/<prefix>/conversations/<AGENT_IDENTITY_*>/dt=<YYYYMMDD>/<serial>/<email>[_<org>]/<session>/<ts>_<uuid>_logs|traces.json.gz
  prefix_slash = var.logs_prefix == "" ? "" : "${var.logs_prefix}/"
  raw_root     = "gs://${var.logs_bucket}/${local.prefix_slash}conversations/"
  # TraceForce's daily metadata snapshots land under this subtree in the customer's logs bucket.
  derived_root = "gs://${var.logs_bucket}/${local.prefix_slash}_traceforce/lakehouse/"
  exports_root = "${local.derived_root}exports/"
  # The managed Iceberg data lives in a module-owned bucket (see bucket.tf), never the logs bucket.
  iceberg_root = "gs://${google_storage_bucket.iceberg.name}/iceberg/"

  # Only these four rails are in the standardized OTLP GenAI format (same as AWS).
  agents = {
    "AGENT_IDENTITY_CLAUDE_CODE"    = 111
    "AGENT_IDENTITY_CURSOR"         = 2
    "AGENT_IDENTITY_CLAUDE"         = 1
    "AGENT_IDENTITY_GITHUB_COPILOT" = 8
  }

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

  # 17 metadata mirror tables from the shared ../schema module.
  export_tables = module.schema.export_tables

  # "name:type" -> { name, type }
  export_columns = {
    for t, cols in local.export_tables : t => [
      for c in cols : { name = split(":", c)[0], type = split(":", c)[1] }
    ]
  }

  # biglake_configuration.connection_id wants project.location.connection (location lowercased).
  connection_ref = "${local.project}.${lower(local.bq_location)}.${google_bigquery_connection.gcs.connection_id}"

  # objects source for the ingest: one SELECT per agent over its hive-partitioned raw table,
  # UNION'd. dt (INT64 partition column) prunes the scan to the last lookback_days upload days;
  # the anti-join skips already-loaded objects (keyed by source_object = _FILE_NAME).
  ingest_objects_sql = join("\n  UNION ALL\n", [
    for a in keys(local.agents) :
    "SELECT _FILE_NAME AS src_path, '${a}' AS agent, resourceLogs, resourceSpans FROM `${local.project}.${var.dataset_id}.${google_bigquery_table.raw_conversations[a].table_id}` WHERE dt >= CAST(FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE(), INTERVAL ${var.lookback_days} - 1 DAY)) AS INT64) AND NOT EXISTS (SELECT 1 FROM `${local.project}.${var.dataset_id}.agent_events` t WHERE t.source_object = _FILE_NAME AND (t.upload_ts >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL ${var.lookback_days} DAY)) OR t.upload_ts IS NULL))"
  ])

  # Rendered ingest SQL (uses the validated template + the two JS routines).
  ingest_sql = templatefile("${path.module}/sql/ingest_agent_events.sql.tftpl", {
    target          = "${local.project}.${var.dataset_id}.agent_events"
    objects_sql     = local.ingest_objects_sql
    dataset         = "${local.project}.${var.dataset_id}"
    agent_type_case = join(" ", [for k, v in local.agents : "WHEN '${k}' THEN ${v}"])
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
