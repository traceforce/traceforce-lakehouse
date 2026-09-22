# --- Values from your TraceForce Storage Provider setup (Settings renders this block) ---

variable "logs_bucket" {
  description = "GCS bucket TraceForce writes agent activity logs to (the Storage Provider you configured in TraceForce Settings). No gs:// prefix."
  type        = string
}

variable "logs_prefix" {
  description = "Key prefix configured for TraceForce in that bucket (may be empty). No leading or trailing slash."
  type        = string
  default     = ""
  validation {
    condition     = !startswith(var.logs_prefix, "/") && !endswith(var.logs_prefix, "/")
    error_message = "logs_prefix must not start or end with '/'."
  }
}

variable "location" {
  description = "BigQuery + connection location; must equal the logs bucket's location (e.g. \"us-east1\" for a regional bucket, or \"US\" for a multi-region)."
  type        = string
}

variable "dataset_id" {
  description = "BigQuery dataset that holds the lakehouse tables. Fixed name assumed by the skill and docs; change only if it collides."
  type        = string
  default     = "traceforce_lakehouse"
}

variable "lookback_days" {
  description = "How many upload-day folders the hourly ingest reads (today plus the days before). 3 is plenty on the schedule; raise for a manual catch-up after an outage."
  type        = number
  default     = 3
  validation {
    condition     = var.lookback_days >= 1 && var.lookback_days == floor(var.lookback_days)
    error_message = "lookback_days must be a whole number >= 1."
  }
}

# --- Only when a separate team will query (they get read-only access to the dataset) ---

variable "query_members" {
  description = "GCP IAM members granted read-only (roles/bigquery.dataViewer) on the dataset, e.g. [\"group:security@acme.com\"] or [\"serviceAccount:...\"]. For when the people running Claude Code query from their own project. They also need roles/bigquery.jobUser in THEIR project (not granted here). Empty = no grant."
  type        = list(string)
  default     = []
}
