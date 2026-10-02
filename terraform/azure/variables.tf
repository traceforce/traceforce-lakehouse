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

# --- Globally-unique name for the storage account this module creates for Iceberg table data ---
variable "iceberg_storage_account_name" {
  description = "Name of the storage account this module creates for Iceberg table data. Globally unique across Azure. Pick it once: changing it later destroys and recreates the account, deleting the Iceberg table files."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.iceberg_storage_account_name)) # Azure's storage account naming rules
    error_message = "iceberg_storage_account_name must be 3-24 lowercase letters/digits only (Azure's own storage account naming rules)."
  }
}

# --- Only when your account differs from the default ---

variable "warehouse_size" {
  description = "Snowflake warehouse size, shared by ad-hoc queries (engineers, Claude Code) and the scheduled ingest/export Tasks (compute.tf). Raise it temporarily for a long lookback_days catch-up."
  type        = string
  default     = "XSMALL"
}

variable "alarm_notification_email" {
  description = "Email to notify when a scheduled Task fails. Must be the verified address of a Snowflake user in this account (Snowflake does not email arbitrary addresses or team lists). Leave null for no notification."
  type        = string
  default     = null
  validation {
    # No quote characters: the value is embedded in a generated SQL string literal (compute.tf).
    condition     = var.alarm_notification_email == null || can(regex("^[^'\"[:space:]]+@[^'\"[:space:]]+\\.[^'\"[:space:]]+$", var.alarm_notification_email))
    error_message = "alarm_notification_email must look like a plain email address with no quote characters or whitespace."
  }
}

# --- Only for a manual catch-up after an outage or a schema replacement ---

variable "lookback_days" {
  description = "How many upload-day folders the hourly ingest reads (today plus the days before). 3 is plenty on the schedule. For a manual catch-up after an outage or a schema replacement, raise it, apply, then set it back: each run is one atomic INSERT over every selected day under the Task's 4-hour timeout (ingest.tf), so for a long catch-up raise lookback_days in increments (apply, let one hourly run finish per TASK_HISTORY, then raise again) or raise warehouse_size for it."
  type        = number
  default     = 3
  validation {
    condition     = var.lookback_days >= 1 && var.lookback_days == floor(var.lookback_days)
    error_message = "lookback_days must be a whole number >= 1."
  }
}

# --- Only when someone should get read access without a manual GRANT ROLE afterward ---

variable "reader_users" {
  description = "Existing Snowflake usernames granted the read-only reader role (query_role.tf), e.g. [\"JDOE\"]. Written as quoted identifiers, so use each user's exact stored name: uppercase unless the user was created with a quoted name. Like AWS's query_trusted_principals / GCP's query_members. Empty = no grant; run GRANT ROLE \"traceforce_lakehouse_reader\" TO USER <name> by hand instead."
  type        = list(string)
  default     = []
}

# --- Only when someone should be emailed as the shared warehouse's credit usage climbs ---

variable "credit_notification_users" {
  description = "Existing non-admin Snowflake usernames (max 5) emailed as the warehouse's monthly credit usage crosses 50/80/100% of the resource monitor's quota (compute.tf), e.g. [\"JDOE\"]: exact stored names (uppercase unless created quoted), each with a verified email in Snowflake, or the monitor's create/update fails. The monitor never suspends the warehouse. Empty = no recipients."
  type        = list(string)
  default     = []
  validation {
    condition     = length(var.credit_notification_users) <= 5 # Snowflake caps NOTIFY_USERS at 5
    error_message = "credit_notification_users can list at most 5 users -- Snowflake's own NOTIFY_USERS limit for a resource monitor."
  }
}
