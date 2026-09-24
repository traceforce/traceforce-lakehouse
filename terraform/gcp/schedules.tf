# The scheduled queries run as this service account (needs to run jobs and write the managed
# tables; it reads GCS through the connection SA, not directly).
resource "google_service_account" "runner" {
  account_id   = "tf-lakehouse-runner"
  display_name = "TraceForce lakehouse scheduled-query runner"
}

resource "google_project_iam_member" "runner_jobuser" {
  project = local.project
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.runner.email}"
}

resource "google_bigquery_dataset_iam_member" "runner_editor" {
  dataset_id = google_bigquery_dataset.lakehouse.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.runner.email}"
}

# Using the connection-bound tables (BigLake external + managed Iceberg) requires
# bigquery.connections.use on the connection for the executing principal; dataEditor does not
# grant it (connections are project-scoped resources).
resource "google_bigquery_connection_iam_member" "runner_conn" {
  connection_id = google_bigquery_connection.gcs.connection_id
  location      = google_bigquery_connection.gcs.location
  role          = "roles/bigquery.connectionUser"
  member        = "serviceAccount:${google_service_account.runner.email}"
}

# Hourly ingest at :57 (a harmless offset off the top of the hour). DTS serializes runs of the
# same config, so the scheduled query never overlaps itself, and the anti-join makes re-running
# the same objects idempotent. Caveat: the anti-join is evaluated at query start, so it does NOT
# protect a manual/ad-hoc run of this SQL fired concurrently with the scheduled one (that could
# double-load) -- don't hand-run the ingest while the hourly may fire.
resource "google_bigquery_data_transfer_config" "ingest" {
  display_name         = "${local.name}-ingest"
  location             = local.bq_location
  data_source_id       = "scheduled_query"
  schedule             = "every 1 hours from 00:57 to 23:57"
  service_account_name = google_service_account.runner.email

  params = {
    query = local.ingest_sql
  }

  depends_on = [
    google_project_service.apis,
    google_bigquery_dataset_iam_member.runner_editor,
    google_project_iam_member.runner_jobuser,
    google_bigquery_table.agent_events,
    google_bigquery_table.raw_telemetry,
  ]
}

# Daily mirror ~12:30 UTC: one multi-statement script of 18 guarded atomic MERGEs (each
# upserts the newest snapshot and deletes rows no longer in it, in one race-free statement).
resource "google_bigquery_data_transfer_config" "mirror" {
  display_name         = "${local.name}-mirror"
  location             = local.bq_location
  data_source_id       = "scheduled_query"
  schedule             = "every day 12:30"
  service_account_name = google_service_account.runner.email

  params = {
    query = local.mirror_sql
  }

  depends_on = [
    google_project_service.apis,
    google_bigquery_dataset_iam_member.runner_editor,
    google_project_iam_member.runner_jobuser,
    google_bigquery_table.export,
    google_bigquery_table.export_src,
  ]
}
