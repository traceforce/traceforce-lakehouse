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

# Ingest SOURCE: external table over the raw gzipped OTLP-JSON objects. Each object is one
# JSON document; resourceLogs/resourceSpans are read as JSON columns (allowed on external
# tables). No hive partitioning: the agent folder is bare (not key=value), so agent and dt
# are derived from _FILE_NAME in the ingest SQL. Read via the connection SA. No metadata cache.
resource "google_bigquery_table" "raw_conversations" {
  dataset_id          = google_bigquery_dataset.lakehouse.dataset_id
  table_id            = "raw_conversations"
  deletion_protection = false

  schema = jsonencode([
    { name = "resourceLogs", type = "JSON", mode = "NULLABLE" },
    { name = "resourceSpans", type = "JSON", mode = "NULLABLE" },
  ])

  external_data_configuration {
    autodetect    = false
    source_format = "NEWLINE_DELIMITED_JSON"
    source_uris   = ["${local.raw_root}*"]
    connection_id = local.connection_ref
  }
}

# 17 snapshot external tables: typed NDJSON so the mirror MERGE needs no casts. Non-hive (like
# raw_conversations) so the table can be created before any snapshots exist; the mirror derives
# dt from _FILE_NAME. Read via the connection SA. No metadata cache.
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
    source_uris   = ["${local.exports_root}${each.key}/*"]
    connection_id = local.connection_ref
  }
}
