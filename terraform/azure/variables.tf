# --- Values from your TraceForce Storage Provider setup (Settings renders this block) ---

variable "logs_storage_account_name" {
  description = "Azure Storage account TraceForce writes agent activity logs to (the Storage Provider you configured in TraceForce Settings)."
  type        = string
}

variable "logs_resource_group_name" {
  description = "Resource group that owns logs_storage_account_name."
  type        = string
}

variable "logs_container_name" {
  description = "Container TraceForce writes agent activity logs to, inside logs_storage_account_name."
  type        = string
}

variable "logs_prefix" {
  description = "Key prefix configured for TraceForce in that container (may be empty). No leading or trailing slash."
  type        = string
  default     = ""
  validation {
    condition     = !startswith(var.logs_prefix, "/") && !endswith(var.logs_prefix, "/")
    error_message = "logs_prefix must not start or end with '/'."
  }
}

# --- Only when your account differs from the default ---

variable "container_name" {
  description = "Name of the new container this module creates inside logs_storage_account_name to hold Iceberg table data. Matches the AWS module's table bucket and the Snowflake database name by default. Overridable (unlike AWS's fixed name) since this container is created inside an account that already exists and could collide with one already there."
  type        = string
  default     = "traceforce-lakehouse"
}

variable "warehouse_size" {
  description = "Snowflake warehouse size for ad-hoc queries from engineers or Claude Code."
  type        = string
  default     = "XSMALL"
}

variable "alarm_notification_email" {
  description = "Email to notify when a scheduled Task fails. Leave null for no notification."
  type        = string
  default     = null
}
