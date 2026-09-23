# agent_events: managed Iceberg table, one row per log record / span. JSON-bearing columns are
# STRING (managed Iceberg forbids JSON). Partitioned by day(ts) and clustered by source_object
# so the hourly anti-join prunes instead of full-scanning.
resource "google_bigquery_table" "agent_events" {
  depends_on          = [time_sleep.iam_propagation]
  dataset_id          = google_bigquery_dataset.lakehouse.dataset_id
  table_id            = "agent_events"
  deletion_protection = false

  schema = jsonencode([
    for c in local.agent_events_schema : {
      name = c.name
      type = local.bq_type[c.type]
      mode = c.required ? "REQUIRED" : "NULLABLE"
    }
  ])

  biglake_configuration {
    connection_id = local.connection_ref
    storage_uri   = "${local.iceberg_root}agent_events/"
    file_format   = "PARQUET"
    table_format  = "ICEBERG"
  }

  time_partitioning {
    type  = "DAY"
    field = "ts"
  }
  clustering = ["source_object"]
}

# 17 metadata mirror tables: managed Iceberg, typed, same names as in TraceForce.
resource "google_bigquery_table" "export" {
  depends_on = [time_sleep.iam_propagation]
  for_each   = local.export_columns

  dataset_id          = google_bigquery_dataset.lakehouse.dataset_id
  table_id            = each.key
  deletion_protection = false

  schema = jsonencode([
    for c in each.value : {
      name = c.name
      type = local.bq_type[c.type]
      mode = c.name == "id" ? "REQUIRED" : "NULLABLE"
    }
  ])

  biglake_configuration {
    connection_id = local.connection_ref
    storage_uri   = "${local.iceberg_root}${each.key}/"
    file_format   = "PARQUET"
    table_format  = "ICEBERG"
  }
}

# Ingest SOURCE: ONE hive-partitioned external table over every OTel activity object scout writes:
#   <root>telemetry/agent=<AGENT_IDENTITY_*>/dt=<YYYYMMDD>/<serial>/<account>/<session>/<ts>_<uuid>_(logs|traces).json.gz
# Both leading segments are Hive key=value, so agent and dt become partition columns (CUSTOM mode
# declares them and needs no files: an agent with no data yet, or an empty bucket, reads as 0 rows)
# and the ingest's `WHERE dt >= ...` PRUNES the scan to the lookback window, matching AWS's partition
# projection. Nothing enumerates agents: a new agent identity shows up in the next hourly run. Browser
# captures and the pre-telemetry/ layouts live under conversations/ and are never matched. Each object
# is one JSON document; resourceLogs/resourceSpans are JSON columns. Read via the connection SA.
resource "google_bigquery_table" "raw_telemetry" {
  dataset_id          = google_bigquery_dataset.lakehouse.dataset_id
  table_id            = "raw_telemetry"
  deletion_protection = false
  # BigQuery serves the partition columns (agent, dt) appended to the schema; without this the
  # provider reads them as removed columns and recreates the table on EVERY plan (provider
  # #12465, fixed by this virtual field in #23633; needs google >= 7.31.0, see versions.tf).
  ignore_auto_generated_schema = true

  # Data columns only; agent (STRING) and dt (INT64, YYYYMMDD) come from the hive CUSTOM prefix below.
  schema = jsonencode([
    { name = "resourceLogs", type = "JSON", mode = "NULLABLE" },
    { name = "resourceSpans", type = "JSON", mode = "NULLABLE" },
  ])

  external_data_configuration {
    autodetect    = false
    source_format = "NEWLINE_DELIMITED_JSON"
    # The objects are gzip. The google provider defaults `compression` to "NONE" and BigQuery honors
    # that literally (it does NOT fall back to the .gz extension), so without this every read parses
    # raw gzip bytes as NDJSON and fails with "Parser terminated before end of string".
    compression   = "GZIP"
    source_uris   = ["${local.raw_root}agent=*"]
    connection_id = local.connection_ref

    hive_partitioning_options {
      mode              = "CUSTOM"
      source_uri_prefix = "${local.raw_root}{agent:STRING}/{dt:INTEGER}"
    }
  }
}

# 17 snapshot external tables: typed NDJSON so the mirror MERGE needs no casts. Non-hive (unlike
# the raw_<agent> tables above) so the table can be created before any snapshots exist; the mirror
# derives dt from _FILE_NAME. Read via the connection SA. No metadata cache.
resource "google_bigquery_table" "export_src" {
  for_each = local.export_columns

  dataset_id          = google_bigquery_dataset.lakehouse.dataset_id
  table_id            = "export_${each.key}"
  deletion_protection = false

  schema = jsonencode([
    for c in each.value : {
      name = c.name
      type = local.bq_type[c.type]
      mode = "NULLABLE"
    }
  ])

  external_data_configuration {
    autodetect    = false
    source_format = "NEWLINE_DELIMITED_JSON"
    compression   = "GZIP" # gzip snapshots; must be explicit, see raw_telemetry above
    source_uris   = ["${local.exports_root}${each.key}/*"]
    connection_id = local.connection_ref
  }
}
