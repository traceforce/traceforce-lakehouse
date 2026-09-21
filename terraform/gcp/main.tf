# The dataset that holds every lakehouse table. Its location must equal the logs bucket's.
resource "google_bigquery_dataset" "lakehouse" {
  depends_on  = [google_project_service.apis]
  dataset_id  = var.dataset_id
  location    = var.location
  description = "TraceForce lakehouse: agent_events (flattened activity) + mirrored metadata, queryable in plain language."

  lifecycle {
    precondition {
      condition     = lower(data.google_storage_bucket.logs.location) == lower(var.location)
      error_message = "var.location (${var.location}) must equal the logs bucket's location (${data.google_storage_bucket.logs.location})."
    }
  }
}

# Cloud-resource connection: BigQuery reads the raw objects and reads/writes the Iceberg data
# in your GCS bucket through this connection's service account.
resource "google_bigquery_connection" "gcs" {
  depends_on    = [google_project_service.apis]
  connection_id = local.name
  location      = var.location
  description   = "TraceForce lakehouse access to the logs bucket (raw + Iceberg data)."
  cloud_resource {}
}

# The connection SA needs to read the raw objects and read/write the Iceberg table data.
resource "google_storage_bucket_iam_member" "connection_gcs" {
  bucket = var.logs_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_bigquery_connection.gcs.cloud_resource[0].service_account_id}"
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

# attrs_json = the decoded attributes minus the four keys that get their own columns.
resource "google_bigquery_routine" "attrs_rest" {
  dataset_id      = google_bigquery_dataset.lakehouse.dataset_id
  routine_id      = "tf_attrs_rest"
  routine_type    = "SCALAR_FUNCTION"
  language        = "JAVASCRIPT"
  definition_body = file("${path.module}/sql/tf_attrs_rest.js")
  arguments {
    name      = "attrs"
    data_type = jsonencode({ typeKind = "JSON" })
  }
  return_type = jsonencode({ typeKind = "JSON" })
}
