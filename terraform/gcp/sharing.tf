# Read-only access for a separate querying team (e.g. security queries from their own project).
# Created only for the members you list. They also need roles/bigquery.jobUser in THEIR project
# (BigQuery queries cross-project natively, so no service-account impersonation is needed).
resource "google_bigquery_dataset_iam_member" "viewers" {
  for_each   = toset(var.query_members)
  dataset_id = google_bigquery_dataset.lakehouse.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = each.value
}

# Querying the managed Iceberg tables (connection-bound) also needs connection use.
resource "google_bigquery_connection_iam_member" "viewers_conn" {
  for_each      = toset(var.query_members)
  connection_id = google_bigquery_connection.gcs.connection_id
  location      = google_bigquery_connection.gcs.location
  role          = "roles/bigquery.connectionUser"
  member        = each.value
}
