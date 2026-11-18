# --- From the cloud module: where the data is, and when its storage access is ready ---

variable "external_volume_name" {
  description = "Name of the cloud module's Snowflake external volume for the Iceberg table data."
  type        = string
}

variable "telemetry_location" {
  description = "Stage location of the telemetry/ folder, whose subfolders are agent=<…>/dt=<…>/, e.g. \"@<stage>/<prefix/>telemetry/\"."
  type        = string
}

variable "exports_location_prefix" {
  description = "Stage location that <table>/ is appended to for each TraceForce export table, e.g. \"@<stage>/<prefix/>_traceforce/lakehouse/exports/\"."
  type        = string
  validation {
    condition     = endswith(var.exports_location_prefix, "/")
    error_message = "exports_location_prefix must end with '/'."
  }
}

variable "raw_ready" {
  description = "An attribute of the cloud module resource that completes once Snowflake can read the raw logs (e.g. its propagation wait's id). The external tables are created after that resource."
  type        = string
}

variable "iceberg_ready" {
  description = "An attribute of the cloud module resource that completes once Snowflake can write the Iceberg storage. The Iceberg tables are created after that resource."
  type        = string
}

# --- Passed through from the cloud module's own inputs (same names, types, defaults) ---

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

variable "lookback_days" {
  description = "How many upload-day folders the hourly ingest reads (today plus the days before). 3 is plenty on the schedule. For a manual catch-up after an outage or a schema replacement, raise it, apply, then set it back: each run is one atomic INSERT over every selected day under the Task's 4-hour timeout (ingest.tf), so for a long catch-up raise lookback_days in increments (apply, let one hourly run finish per TASK_HISTORY, then raise again) or raise warehouse_size for it."
  type        = number
  default     = 3
  validation {
    condition     = var.lookback_days >= 1 && var.lookback_days == floor(var.lookback_days)
    error_message = "lookback_days must be a whole number >= 1."
  }
}

variable "reader_users" {
  description = "Existing Snowflake usernames granted the read-only reader role (query_role.tf), e.g. [\"JDOE\"]. Written as quoted identifiers, so use each user's exact stored name: uppercase unless the user was created with a quoted name. Like AWS's query_trusted_principals / GCP's query_members. Empty = no grant; run GRANT ROLE \"traceforce_lakehouse_reader\" TO USER <name> by hand instead."
  type        = list(string)
  default     = []
}

variable "credit_notification_users" {
  description = "Existing non-admin Snowflake usernames (max 5) emailed as the warehouse's monthly credit usage crosses 50/80/100% of the resource monitor's quota (compute.tf), e.g. [\"JDOE\"]: exact stored names (uppercase unless created quoted), each with a verified email in Snowflake, or the monitor's create/update fails. The monitor never suspends the warehouse. Empty = no recipients."
  type        = list(string)
  default     = []
  validation {
    condition     = length(var.credit_notification_users) <= 5 # Snowflake caps NOTIFY_USERS at 5
    error_message = "credit_notification_users can list at most 5 users -- Snowflake's own NOTIFY_USERS limit for a resource monitor."
  }
}

variable "query_user_public_key" {
  description = "RSA public key for a dedicated read-only query user the module creates, traceforce_lakehouse_query (one line, without the BEGIN/END PUBLIC KEY lines). A SERVICE user that holds only the reader role, with secondary roles off, UTC and a 300 s statement timeout, so the identity itself is read-only whatever client connects -- the Snowflake counterpart of the Athena module's query role. Null = create no user; grant the reader role to existing users with reader_users or by hand."
  type        = string
  default     = null
  validation {
    condition     = var.query_user_public_key == null || can(regex("^[A-Za-z0-9+/=]+$", var.query_user_public_key))
    error_message = "query_user_public_key must be the base64 body of the public key on one line, without the BEGIN/END PUBLIC KEY lines."
  }
}

variable "dashboard_sign_in" {
  description = "Sign-in for the TraceForce UI dashboards (dashboard_sign_in.tf). console_origin is the https origin you open the TraceForce console at. Set snowflake = {} for Snowflake's own sign-in, external = { ... } for the company's identity provider, or both. Null = no dashboard sign-in."
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
