# --- Values from your TraceForce Storage Provider setup (Settings renders this block) ---

variable "logs_bucket" {
  description = "S3 bucket TraceForce writes agent activity logs to (the Storage Provider you configured in TraceForce Settings)."
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

# --- Only when your account differs from the default ---

variable "logs_kms_key_arn" {
  description = "KMS key ARN if logs_bucket uses SSE-KMS with a customer-managed key (the ingest must be able to decrypt the logs). Leave null for SSE-S3."
  type        = string
  default     = null
}

variable "alarm_sns_topic_arn" {
  description = "SNS topic to notify when a scheduled run fails (the alarm exists either way and shows ALARM in the CloudWatch console). Leave null for no notification."
  type        = string
  default     = null
}

variable "create_glue_integration" {
  description = "Create the account-level Glue federated catalog 's3tablescatalog' that lets Athena query S3 Tables. There is exactly one per account and region; set false if it already exists (e.g. you enabled the integration when creating another table bucket)."
  type        = bool
  default     = true
}
