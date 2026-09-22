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

