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

# Ingest SOURCE: one hive-partitioned external table PER agent over the raw gzipped OTLP-JSON
# objects (each object is one JSON document; resourceLogs/resourceSpans are JSON columns). One
# table per agent because the layout is <agent>/dt=<YYYYMMDD>/... : the bare <agent> segment can't
# be a hive key, but rooting each table at its own agent folder makes dt=<YYYYMMDD> a hive
# partition column (INT64), so the ingest's `WHERE dt >= ...` PRUNES the bytes scanned to the
# lookback window (matching AWS's partition projection) instead of full-scanning all history every
# hourly run. Scoping source_uris to <agent>/dt=* also excludes both the pre-dt= legacy serial
# folders and the claude.ai/ChatGPT browser-capture .zip objects (short AGENT_CLAUDE/ AGENT_CHATGPT/
# folders, wrong format) -- BigQuery would fail parsing those as NDJSON. Read via the connection SA.
resource "google_bigquery_table" "raw_conversations" {
  for_each            = local.agents
  dataset_id          = google_bigquery_dataset.lakehouse.dataset_id
  table_id            = "raw_${lower(each.key)}"
  deletion_protection = false

  # Data columns only; the dt partition column (INT64, YYYYMMDD) is declared by hive CUSTOM below.
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
    source_uris   = ["${local.raw_root}${each.key}/dt=*"]
    connection_id = local.connection_ref

    hive_partitioning_options {
      # CUSTOM (not AUTO): declare dt's name+type explicitly so the table works even for an agent
      # with no data yet. AUTO infers the partition schema by LISTING objects, so an empty agent
      # folder (common -- most customers don't run all four agents) fails with "cannot query hive
      # partitioned data ... without any associated files", which would abort the whole UNION ingest.
      # CUSTOM needs no files, matching AWS partition projection's tolerance of empty agents.
      mode              = "CUSTOM"
      source_uri_prefix = "${local.raw_root}${each.key}/{dt:INTEGER}"
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
    compression   = "GZIP" # gzip snapshots; must be explicit, see raw_conversations above
    source_uris   = ["${local.exports_root}${each.key}/*"]
    connection_id = local.connection_ref
  }
}
