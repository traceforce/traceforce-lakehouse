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
# Required, with no default: must be a plain, explicit value, not derived from any other input.
variable "iceberg_storage_account_name" {
  description = "Name for the Azure Storage account this module creates to hold Iceberg table data (storage.tf) -- must be globally unique across all of Azure, since storage account names share one namespace account-wide. Pick it once; changing it later makes Terraform destroy and recreate the storage account, deleting the Iceberg table files."
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

variable "container_name" {
  description = "Name of the container this module creates (in its own module-owned storage account, not logs_storage_account_name) to hold Iceberg table data. Matches the Snowflake database name by default."
  type        = string
  default     = "traceforce-lakehouse"
  validation {
    # Rejects Azure's reserved containers, matching the same product decision this module's
    # Go-side config validation already makes for the customer-facing logs container ($root in
    # particular also already exists implicitly on every storage account, so creating a
    # container by this name here wouldn't make a new one -- it would point Iceberg table data
    # at the account's own root blob namespace instead).
    condition     = !contains(["$root", "$web", "$logs", "$blobchangefeed"], lower(var.container_name))
    error_message = "container_name can't be one of Azure's reserved containers ($root, $web, $logs, $blobchangefeed)."
  }
}

variable "warehouse_size" {
  description = "Snowflake warehouse size for ad-hoc queries from engineers or Claude Code."
  type        = string
  default     = "XSMALL"
}

variable "alarm_notification_email" {
  description = "Email to notify when a scheduled Task fails. Leave null for no notification. Must be a verified email address of a Snowflake user in this account -- Snowflake only emails addresses its own users have verified (Snowsight or the Classic Console), not arbitrary addresses or team distribution lists; CREATE NOTIFICATION INTEGRATION fails on apply otherwise."
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
  description = "Existing Snowflake usernames to grant the read-only reader role (query_role.tf) to, e.g. [\"JDOE\"]. Matches AWS's query_trusted_principals / GCP's query_members -- for when the engineers/Claude Code querying the lakehouse aren't the ones running this Terraform. Empty = no grant; run GRANT ROLE \"traceforce_lakehouse_reader\" TO USER <you> by hand instead (quoted -- the role is created as a case-preserved lowercase identifier)."
  type        = list(string)
  default     = []
}

# --- Only when someone should be emailed as the shared warehouse's credit usage climbs ---

variable "credit_notification_users" {
  description = "Existing Snowflake usernames to email as the warehouse's monthly credit usage crosses 50%/80%/100% of credit_quota (compute.tf), in addition to any account administrator who has separately opted in to resource-monitor notifications for themselves -- e.g. [\"JDOE\"]. Snowflake emails each listed user's own verified address directly; do not list an administrator here, since this list is for non-administrator users only (max 5) -- an opted-in admin is notified either way, regardless of this list. The monitor itself never suspends the warehouse, so these are the only way usage climbing out of band gets noticed. Empty = no additional non-admin recipients."
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
