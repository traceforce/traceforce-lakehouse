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
  description = "Size of traceforce_lakehouse, the warehouse that runs the scheduled ingest/export Tasks (compute.tf); readers query on traceforce_lakehouse_query (query_warehouse_size). Raise it temporarily for a long lookback_days catch-up."
  type        = string
  default     = "XSMALL"
}

variable "query_warehouse_size" {
  description = "Size of the query warehouse, traceforce_lakehouse_query, that readers run on (the skill, the dashboards). Raise it if queries feel slow."
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

# --- Only when the module should create the read-only query user itself ---

variable "query_user_public_key" {
  description = "RSA public key for a dedicated read-only query user the module creates, traceforce_lakehouse_query (one line, without the BEGIN/END PUBLIC KEY lines). A SERVICE user that holds only the reader role, with secondary roles off, UTC and a 300 s statement timeout, so the identity itself is read-only whatever client connects -- the Azure counterpart of AWS's query role. Null = create no user; grant the reader role to existing users with reader_users or by hand."
  type        = string
  default     = null
  validation {
    condition     = var.query_user_public_key == null || can(regex("^[A-Za-z0-9+/=]+$", var.query_user_public_key))
    error_message = "query_user_public_key must be the base64 body of the public key on one line, without the BEGIN/END PUBLIC KEY lines."
  }
}

variable "dashboard_sign_in" {
  description = "Sign-in for the TraceForce UI dashboards (dashboard_sign_in.tf; with snowflake, also the token relay in dashboard_relay.tf). console_origin is the https origin you open the TraceForce console at. Set snowflake = {} for Snowflake's own sign-in, external = { ... } for the company's identity provider, or both. Null = no dashboard sign-in."
  type = object({
    console_origin = string
    snowflake = optional(object({
      refresh_token_validity = optional(number, 86400) # seconds a viewer stays signed in
    }))
    external = optional(object({
      provider                 = string           # "entra", "okta" or "custom"
      audience                 = string           # Entra: the resource app's Application ID URI; Okta: the authorization server's audience
      tenant_id                = optional(string) # Entra
      issuer                   = optional(string) # Okta (a custom authorization server: https://<org>.okta.com/oauth2/<id>) and custom
      jws_keys_url             = optional(string) # custom; derived for Entra and Okta
      user_claim               = optional(string) # default: upn for Entra, sub otherwise
      snowflake_user_attribute = optional(string, "login_name")
    }))
  })
  default = null

  validation {
    # Written as browsers send it in Origin, which the relay compares exactly: no default :443, no
    # leading zeros in a port.
    condition = var.dashboard_sign_in == null || (
      can(regex("^https://[a-z0-9.-]+(:[1-9][0-9]{0,4})?/?$", var.dashboard_sign_in.console_origin)) &&
      !can(regex(":443/?$", var.dashboard_sign_in.console_origin))
    )
    error_message = "dashboard_sign_in.console_origin must be the TraceForce console's https origin as the browser sends it: scheme and host, lowercase, no path, no :443."
  }
  validation {
    condition     = var.dashboard_sign_in == null || try(var.dashboard_sign_in.snowflake != null || var.dashboard_sign_in.external != null, false)
    error_message = "dashboard_sign_in needs snowflake = {}, external = { ... } or both."
  }
  validation {
    # Snowflake's range for custom clients; a shorter one needs Snowflake Support to lower the account's minimum.
    condition     = try(var.dashboard_sign_in.snowflake.refresh_token_validity, 86400) >= 86400 && try(var.dashboard_sign_in.snowflake.refresh_token_validity, 86400) <= 7776000
    error_message = "dashboard_sign_in.snowflake.refresh_token_validity must be between 86400 (1 day) and 7776000 (90 days) seconds, Snowflake's range for custom OAuth clients."
  }
  validation {
    condition     = try(var.dashboard_sign_in.external, null) == null || contains(["entra", "okta", "custom"], try(var.dashboard_sign_in.external.provider, ""))
    error_message = "dashboard_sign_in.external.provider must be \"entra\", \"okta\" or \"custom\"."
  }
  validation {
    condition     = try(var.dashboard_sign_in.external.provider, "") != "entra" || can(regex("^[0-9a-fA-F-]{36}$", var.dashboard_sign_in.external.tenant_id))
    error_message = "dashboard_sign_in.external with provider \"entra\" needs tenant_id, the Entra tenant's GUID."
  }
  validation {
    condition     = !contains(["okta", "custom"], try(var.dashboard_sign_in.external.provider, "")) || can(regex("^https://", var.dashboard_sign_in.external.issuer))
    error_message = "dashboard_sign_in.external with provider \"okta\" or \"custom\" needs issuer, the authorization server's https issuer URL."
  }
  validation {
    condition     = try(var.dashboard_sign_in.external.provider, "") != "custom" || can(regex("^https://", var.dashboard_sign_in.external.jws_keys_url))
    error_message = "dashboard_sign_in.external with provider \"custom\" needs jws_keys_url, the https URL of the server's signing keys."
  }
  validation {
    condition     = try(var.dashboard_sign_in.external, null) == null || try(length(trimspace(var.dashboard_sign_in.external.audience)) > 0, false)
    error_message = "dashboard_sign_in.external.audience must not be empty."
  }
}
