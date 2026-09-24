# The dataset that holds every lakehouse table. Its location is the logs bucket's (BQ co-locates).
resource "google_bigquery_dataset" "lakehouse" {
  depends_on  = [google_project_service.apis]
  dataset_id  = var.dataset_id
  location    = local.bq_location
  description = "TraceForce lakehouse: agent_events (flattened activity) + mirrored metadata, queryable in plain language."
}

# Cloud-resource connection: BigQuery reads the raw objects and reads/writes the Iceberg data
# in your GCS bucket through this connection's service account.
resource "google_bigquery_connection" "gcs" {
  depends_on    = [google_project_service.apis]
  connection_id = local.name
  location      = local.bq_location
  description   = "TraceForce lakehouse access to the logs bucket (raw + Iceberg data)."
  cloud_resource {}
}

# BigQuery provisions the connection's service account ASYNCHRONOUSLY: terraform gets its email back
# immediately, but the IAM backend does not yet know the identity, so binding a role to it in the
# same apply can fail with "Service account bqcx-...@gcp-sa-bigquery-condel.iam.gserviceaccount.com
# does not exist" (observed on a fresh apply; re-running then succeeds). This short wait lets the SA
# register before the two grants below reference it, so a customer's first apply is one-shot. Keyed
# on the SA email so it re-fires if the connection (hence its SA) is ever replaced; the grants take
# the email from here, which is what orders them after the wait.
resource "time_sleep" "connection_sa_ready" {
  triggers        = { sa = google_bigquery_connection.gcs.cloud_resource[0].service_account_id }
  create_duration = "30s"
}

# The connection SA's access is split so it holds NO write/delete on the customer's data:
#  - customer logs bucket: READ-ONLY (objectViewer + legacyBucketReader) -- it only reads the raw
#    activity objects and the daily export snapshots there.
#  - module-owned Iceberg bucket: read/write (objectUser + legacyBucketReader), where the managed
#    Iceberg data lives. Google's managed-Iceberg docs prescribe objectUser (object read/write incl.
#    compaction) + legacyBucketReader (bucket-level buckets.get objectUser lacks); objectAdmin would
#    only add per-object set/getIamPolicy, which Iceberg never uses.
resource "google_storage_bucket_iam_member" "connection_logs_read" {
  for_each = toset(["roles/storage.objectViewer", "roles/storage.legacyBucketReader"])
  bucket   = var.logs_bucket
  role     = each.value
  member   = "serviceAccount:${time_sleep.connection_sa_ready.triggers.sa}"
}

resource "google_storage_bucket_iam_member" "connection_iceberg_rw" {
  for_each = toset(["roles/storage.objectUser", "roles/storage.legacyBucketReader"])
  bucket   = google_storage_bucket.iceberg.name
  role     = each.value
  member   = "serviceAccount:${time_sleep.connection_sa_ready.triggers.sa}"
}

# GCS IAM is eventually consistent (Google: "typically 2 minutes, potentially 7 minutes or
# longer"), so let the connection SA's grants propagate before the managed Iceberg tables write
# their first metadata object, else table creation can hit a transient storage.objects.create
# denial. A fixed wait can't cover the 7-min tail; if a create still races, re-running apply is
# idempotent (the empty table recreates). 180s covers the typical case. Keyed on the same SA as
# the wait above so a connection replacement re-runs the whole chain (new SA -> new grants ->
# propagate -> tables).
resource "time_sleep" "iam_propagation" {
  depends_on      = [google_storage_bucket_iam_member.connection_logs_read, google_storage_bucket_iam_member.connection_iceberg_rw]
  triggers        = { sa = time_sleep.connection_sa_ready.triggers.sa }
  create_duration = "180s"
}

# OTLP attribute decode (first-value-wins, scalars->text, arrayValue->[], kvlist->object),
# matching the AWS/Trino ingest. Used by the ingest SQL on resource and record attributes.
resource "google_bigquery_routine" "otlp_attrs" {
  dataset_id      = google_bigquery_dataset.lakehouse.dataset_id
  routine_id      = "tf_otlp_attrs"
  routine_type    = "SCALAR_FUNCTION"
  language        = "JAVASCRIPT"
  definition_body = file("${path.module}/sql/tf_otlp_attrs.js")
  arguments {
    name      = "attrs"
    data_type = jsonencode({ typeKind = "JSON" })
  }
  return_type = jsonencode({ typeKind = "JSON" })
}

