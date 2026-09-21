output "dataset_id" {
  description = "BigQuery dataset holding the lakehouse tables."
  value       = google_bigquery_dataset.lakehouse.dataset_id
}

output "agent_events_fqn" {
  description = "Fully qualified table name for GoogleSQL."
  value       = "${local.project}.${var.dataset_id}.agent_events"
}

output "exports_root" {
  description = "Where TraceForce's export job writes <table>/dt=YYYY-MM-DD/<HHMMSS>.jsonl.gz"
  value       = local.exports_root
}

output "query_setup" {
  description = "How the querying team points their agent at the lakehouse."
  value       = <<-EOT
    Query the lakehouse from BigQuery in project ${local.project}, dataset ${var.dataset_id}
    (location ${var.location}). If your team queries from another project, we granted the
    members in query_members roles/bigquery.dataViewer here; they also need roles/bigquery.jobUser
    in their own project. Point the agent at ${local.project}.${var.dataset_id}.agent_events.
  EOT
}
