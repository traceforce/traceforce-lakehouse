# --- Values from your TraceForce Storage Provider setup (Settings renders this block) ---

variable "logs_storage_account_name" {
  description = "Azure Storage account TraceForce writes agent activity logs to (the Storage Provider you configured in TraceForce Settings). Must be ADLS Gen2 (hierarchical namespace enabled)."
  type        = string
}

variable "logs_resource_group_name" {
  description = "Resource group that owns logs_storage_account_name. Every resource this module creates goes in this resource group."
  type        = string
}

variable "logs_container_name" {
  description = "Container TraceForce writes agent activity logs to, inside logs_storage_account_name."
  type        = string
}

variable "logs_prefix" {
  description = "Key prefix configured for TraceForce in that container (may be empty). No leading or trailing slash. Letters and digits (any language) and . _ = - @ + ~ , : ; & $ ! ( ) only, with '/' between non-empty segments."
  type        = string
  default     = ""
  validation {
    condition     = !startswith(var.logs_prefix, "/") && !endswith(var.logs_prefix, "/")
    error_message = "logs_prefix must not start or end with '/'."
  }
  # Only characters tested end to end: the prefix goes into the external location's URL, SQL
  # string literals and read_files() paths. Unity Catalog rejects a URL with a space, % \ [ ] { }
  # or an empty segment; # and a space or % make the mirror find no snapshot; ' breaks the SQL;
  # * ? [ ] { } are read_files() glob characters; " (untested) quotes text inside the SQL.
  validation {
    condition     = can(regex("^([\\p{L}\\p{N}._=@+~,:;&$!()-]+(/[\\p{L}\\p{N}._=@+~,:;&$!()-]+)*)?$", var.logs_prefix))
    error_message = "logs_prefix may contain only letters, digits and . _ = - @ + ~ , : ; & $ ! ( ), with '/' between non-empty segments. A space, % # \\ ' \" * ? [ ] { } or an empty segment breaks the Unity Catalog URL or the SQL."
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

# --- The Databricks catalog this module creates ---

variable "catalog_name" {
  description = "Unity Catalog catalog name. Unique within the region's metastore: two lakehouses in one region under one Databricks account need different names. Pick it once: changing it later replaces the catalog and its grants."
  type        = string
  default     = "traceforce_lakehouse"
  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.catalog_name))
    error_message = "catalog_name must start with a lowercase letter and contain only lowercase letters, digits and underscores (at most 63 characters)."
  }
}

# --- The Databricks workspace this module creates ---

variable "databricks_workspace_name" {
  description = "Name of the Premium Azure Databricks workspace this module creates in logs_resource_group_name. Pick it once: changing it later replaces the workspace and everything in it."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{3,64}$", var.databricks_workspace_name)) # Azure's Databricks workspace naming rules
    error_message = "databricks_workspace_name must be 3-64 letters, digits, underscores or hyphens (Azure's own Databricks workspace naming rules)."
  }
}

# --- Only when your account differs from the default ---

variable "ingest_warehouse_size" {
  description = "Size of the SQL warehouse the scheduled ingest and mirror jobs run on: 2X-Small, X-Small, Small, Medium, Large, X-Large, 2X-Large, 3X-Large, 4X-Large or 5X-Large. Raise it temporarily for a long lookback_days catch-up."
  type        = string
  default     = "2X-Small"
  validation {
    condition     = contains(["2X-Small", "X-Small", "Small", "Medium", "Large", "X-Large", "2X-Large", "3X-Large", "4X-Large", "5X-Large"], var.ingest_warehouse_size)
    error_message = "ingest_warehouse_size must be one of 2X-Small, X-Small, Small, Medium, Large, X-Large, 2X-Large, 3X-Large, 4X-Large, 5X-Large."
  }
}

variable "query_warehouse_size" {
  description = "Size of the SQL warehouse for ad-hoc queries (readers, engineers, Claude Code, the in-app dashboards): 2X-Small, X-Small, Small, Medium, Large, X-Large, 2X-Large, 3X-Large, 4X-Large or 5X-Large. Raise it if large queries are slow."
  type        = string
  default     = "2X-Small"
  validation {
    condition     = contains(["2X-Small", "X-Small", "Small", "Medium", "Large", "X-Large", "2X-Large", "3X-Large", "4X-Large", "5X-Large"], var.query_warehouse_size)
    error_message = "query_warehouse_size must be one of 2X-Small, X-Small, Small, Medium, Large, X-Large, 2X-Large, 3X-Large, 4X-Large, 5X-Large."
  }
}

variable "query_max_num_clusters" {
  description = "Most clusters the query warehouse scales out to when many queries run at once. 1 is the cheapest and enough for most teams; raise it if dashboard or Claude Code queries queue behind each other."
  type        = number
  default     = 1
  validation {
    condition     = var.query_max_num_clusters >= 1 && var.query_max_num_clusters == floor(var.query_max_num_clusters)
    error_message = "query_max_num_clusters must be a whole number >= 1."
  }
}

variable "query_auto_stop_mins" {
  description = "Minutes the query warehouse stays up after its last query. 1 is the cheapest, but the first query after an idle minute waits for a cold start; raise it (e.g. 10) if dashboard or Claude Code sessions feel slow. Billed while it's up, so a higher value costs more."
  type        = number
  default     = 1
  validation {
    condition     = var.query_auto_stop_mins >= 1 && var.query_auto_stop_mins == floor(var.query_auto_stop_mins)
    error_message = "query_auto_stop_mins must be a whole number >= 1."
  }
}

variable "databricks_account_id" {
  description = "Your Databricks account ID (a UUID, not a workspace ID). Optional: unset, it's read from the workspace with the databricks_workspace_iam_service_principal_v2 data source (Public Beta); set it to avoid that dependency, or if plan or apply fails with an error from that data source (e.g. \"failed to get workspace_iam_service_principal_v2\"). Shown in the account console (top-right user menu; account admins only). Used only to name the ingest service principal's role rule set."
  type        = string
  default     = null
  validation {
    condition     = var.databricks_account_id == null || can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.databricks_account_id))
    error_message = "databricks_account_id must be the account's UUID in lowercase, e.g. 01234567-89ab-cdef-0123-456789abcdef, or unset."
  }
}

variable "additional_deployer_user_names" {
  description = "Databricks user names (the user's email, in lowercase) that may deploy this module later, besides whoever runs terraform apply, e.g. [\"jdoe@acme.com\"]. They must also be workspace admins. Each gets the Service Principal User and Manager roles on the ingest service principal. Applying needs both (User to set the jobs' run_as, Manager to update the roles), and the role rule set is authoritative: only the identity running apply and the identities listed in the three additional_deployer_* inputs keep them. List everyone who deploys, yourself included, best as one account group (plus your CI's service principal): anyone not listed loses both roles the next time someone else applies."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for n in var.additional_deployer_user_names : trimspace(n) != ""])
    error_message = "additional_deployer_user_names entries must not be empty."
  }
  # Databricks stores user names and application IDs in lowercase, and the role rule set
  # (run_as.tf) names each principal as typed, so it must be written the same way.
  validation {
    condition     = alltrue([for n in var.additional_deployer_user_names : n == lower(n)])
    error_message = "additional_deployer_user_names entries must be in lowercase, e.g. jdoe@acme.com."
  }
}

variable "additional_deployer_group_names" {
  description = "Databricks account group names (exact, case-sensitive) that may deploy this module later, besides whoever runs terraform apply, e.g. [\"platform-team\"]. They must also be workspace admins. Each gets the Service Principal User and Manager roles on the ingest service principal. Applying needs both (User to set the jobs' run_as, Manager to update the roles), and the role rule set is authoritative: only the identity running apply and the identities listed in the three additional_deployer_* inputs keep them. List everyone who deploys, yourself included, best as one account group (plus your CI's service principal): anyone not listed loses both roles the next time someone else applies."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for n in var.additional_deployer_group_names : trimspace(n) != ""])
    error_message = "additional_deployer_group_names entries must not be empty."
  }
}

variable "additional_deployer_service_principal_names" {
  description = "Service principal application IDs in lowercase (e.g. your CI's) that may deploy this module later, besides whoever runs terraform apply, e.g. [\"<application id>\"]. They must also be workspace admins. Each gets the Service Principal User and Manager roles on the ingest service principal. Applying needs both (User to set the jobs' run_as, Manager to update the roles), and the role rule set is authoritative: only the identity running apply and the identities listed in the three additional_deployer_* inputs keep them. List everyone who deploys, yourself included, best as one account group (plus your CI's service principal): anyone not listed loses both roles the next time someone else applies."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for n in var.additional_deployer_service_principal_names : trimspace(n) != ""])
    error_message = "additional_deployer_service_principal_names entries must not be empty."
  }
  # Databricks stores user names and application IDs in lowercase, and the role rule set
  # (run_as.tf) names each principal as typed, so it must be written the same way.
  validation {
    condition     = alltrue([for n in var.additional_deployer_service_principal_names : n == lower(n)])
    error_message = "additional_deployer_service_principal_names entries must be in lowercase."
  }
}

variable "alarm_notification_email" {
  description = "Email to notify when a scheduled job fails, and when data goes stale (the freshness alert: once, then daily while it lasts, and again when it clears). Any address; it needn't be a Databricks user. Leave null for no notifications."
  type        = string
  default     = null
  validation {
    condition     = var.alarm_notification_email == null || can(regex("^[^'\"[:space:]]+@[^'\"[:space:]]+\\.[^'\"[:space:]]+$", var.alarm_notification_email))
    error_message = "alarm_notification_email must look like a plain email address with no quote characters or whitespace."
  }
}

# --- Only for a manual catch-up after an outage or a schema replacement ---

variable "lookback_days" {
  description = "How many upload-day folders the hourly ingest reads (today plus the days before). 3 is plenty on the schedule. For a manual catch-up after an outage or a schema replacement, raise it, apply, let one hourly run finish, then set it back; raise ingest_warehouse_size for a long catch-up."
  type        = number
  default     = 3
  validation {
    condition     = var.lookback_days >= 1 && var.lookback_days == floor(var.lookback_days)
    error_message = "lookback_days must be a whole number >= 1."
  }
}

# --- Only when someone should get read access without a manual GRANT afterward ---

# Readers: each listed principal gets SELECT on the lakehouse tables, use of the query warehouse and
# view access to the ingest and mirror jobs (run history), and also needs the workspace entitlement
# Databricks SQL access. One list per kind of principal, named after the fields Databricks'
# permissions take (user_name, group_name, service_principal_name); each entry is looked up and
# granted under the name Databricks stores. Add readers here rather than by hand: the query
# warehouse's and jobs' permissions are managed by this module, so hand-made grants on them are
# removed on the next apply.

variable "reader_user_names" {
  description = "Databricks user names (the user's email, in lowercase) granted read-only access to the lakehouse, e.g. [\"jdoe@acme.com\"]. Each also needs the workspace entitlement Databricks SQL access. Don't list anyone who runs terraform apply, including the additional_deployer_* identities: the plan is refused when a listed reader runs apply."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for n in var.reader_user_names : trimspace(n) != ""])
    error_message = "reader_user_names entries must not be empty."
  }
  # Databricks stores user names and application IDs in lowercase. Any pending change to the
  # workspace makes Terraform read the reader lookups during apply and plan the grants with the
  # entry as typed, so an entry with capitals would replace its grants, revoking them during the
  # apply (query_access.tf).
  validation {
    condition     = alltrue([for n in var.reader_user_names : n == lower(n)])
    error_message = "reader_user_names entries must be in lowercase, e.g. jdoe@acme.com."
  }
}

variable "reader_group_names" {
  description = "Databricks account group names granted read-only access to the lakehouse, e.g. [\"security-team\"]. Account groups only: workspace-local groups can't hold Unity Catalog grants. To give everyone access, create an account group with everyone in it. Members also need the workspace entitlement Databricks SQL access."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for n in var.reader_group_names : trimspace(n) != ""])
    error_message = "reader_group_names entries must not be empty."
  }
  # The workspace's built-in groups: found by the reader lookup, so without this the query warehouse
  # and jobs permissions apply and only the Unity Catalog grants fail, leaving a half-done apply.
  validation {
    condition     = length(setintersection(var.reader_group_names, ["users", "admins"])) == 0
    error_message = "reader_group_names can't include users or admins: they're workspace-only groups, which Unity Catalog can't grant to. Use an account group."
  }
}

variable "reader_service_principal_names" {
  description = "Service principal application IDs in lowercase granted read-only access to the lakehouse, e.g. a service principal you create, with its own secret, as a read-only identity for Claude Code. Each also needs the workspace entitlement Databricks SQL access. Don't list the ingest service principal, or a service principal that runs terraform apply (e.g. CI)."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for n in var.reader_service_principal_names : trimspace(n) != ""])
    error_message = "reader_service_principal_names entries must not be empty."
  }
  # Databricks stores user names and application IDs in lowercase. Any pending change to the
  # workspace makes Terraform read the reader lookups during apply and plan the grants with the
  # entry as typed, so an entry with capitals would replace its grants, revoking them during the
  # apply (query_access.tf).
  validation {
    condition     = alltrue([for n in var.reader_service_principal_names : n == lower(n)])
    error_message = "reader_service_principal_names entries must be in lowercase."
  }
}

variable "reader_can_view_jobs" {
  description = "Whether the readers also get CAN_VIEW on the ingest and mirror jobs: their run history, including each task's SQL and error messages, in the Jobs UI and API. Off by default: readers get lakehouse access only."
  type        = bool
  default     = false
}
