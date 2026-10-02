# --- Values from your TraceForce Storage Provider setup (Settings renders this block) ---
# Assumes you've already configured the Azure Blob Storage Provider integration per
# https://traceforce.readme.io/docs/storage-provider-integration#azure-blob-storage --
# this module reads the account/container TraceForce is already writing to, it doesn't set
# that integration up.

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
    # Azure's own naming rules for a storage account: 3-24 characters, lowercase letters and
    # digits only, no hyphens -- checked here so a bad name fails at `terraform plan`, not only
    # once Azure itself rejects the CREATE.
    condition     = can(regex("^[a-z0-9]{3,24}$", var.iceberg_storage_account_name))
    error_message = "iceberg_storage_account_name must be 3-24 lowercase letters/digits only (Azure's own storage account naming rules)."
  }
}

# --- Only when your account differs from the default ---

variable "warehouse_size" {
  description = "Snowflake warehouse size for ad-hoc queries from engineers or Claude Code."
  type        = string
  default     = "XSMALL"
}

variable "alarm_notification_email" {
  description = "Email to notify when a scheduled Task fails. Must be the verified address of a Snowflake user in this account (Snowflake does not email arbitrary addresses or team lists). Leave null for no notification."
  type        = string
  default     = null
  validation {
    # Rejects quote characters specifically: this value is embedded directly in a generated
    # SQL string literal (compute.tf's alert action), so a stray ' or " could break or alter
    # that statement. A real email address never legitimately contains either.
    condition     = var.alarm_notification_email == null || can(regex("^[^'\"[:space:]]+@[^'\"[:space:]]+\\.[^'\"[:space:]]+$", var.alarm_notification_email))
    error_message = "alarm_notification_email must look like a plain email address with no quote characters or whitespace."
  }
}

# --- Only for a manual catch-up after an outage or a schema replacement ---

variable "lookback_days" {
  description = "How many upload-day folders the hourly ingest reads (today plus the days before). 3 is plenty on the schedule; raise it, apply, then set it back for a manual catch-up after an outage or a schema replacement."
  type        = number
  default     = 3
  validation {
    condition     = var.lookback_days >= 1 && var.lookback_days == floor(var.lookback_days)
    error_message = "lookback_days must be a whole number >= 1."
  }
}

# --- Only when someone should get read access without a manual GRANT ROLE afterward ---

variable "reader_users" {
  description = "Existing Snowflake usernames granted the read-only reader role (query_role.tf), e.g. [\"JDOE\"]. Like AWS's query_trusted_principals / GCP's query_members. Empty = no grant; run GRANT ROLE \"traceforce_lakehouse_reader\" TO USER <name> by hand instead."
  type        = list(string)
  default     = []
}

# --- Only when someone should be emailed as the shared warehouse's credit usage climbs ---

variable "credit_notification_users" {
  description = "Existing non-admin Snowflake usernames (max 5) emailed as the warehouse's monthly credit usage crosses 50/80/100% of the resource monitor's quota (compute.tf), e.g. [\"JDOE\"]. The monitor never suspends the warehouse. Empty = no recipients."
  type        = list(string)
  default     = []
  validation {
    # Snowflake's own CREATE/ALTER RESOURCE MONITOR caps NOTIFY_USERS at 5 non-admin users --
    # checked here so a too-long list fails at `terraform plan`, not only once the resource
    # monitor itself is created/updated and Snowflake rejects it.
    condition     = length(var.credit_notification_users) <= 5
    error_message = "credit_notification_users can list at most 5 users -- Snowflake's own NOTIFY_USERS limit for a resource monitor."
  }
}
