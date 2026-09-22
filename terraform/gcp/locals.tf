data "google_project" "this" {}

# The logs bucket, read so residency is explicit and the module fails fast if the location is wrong.
data "google_storage_bucket" "logs" {
  name = var.logs_bucket
}

locals {
  project = data.google_project.this.project_id

  # Where TraceForce's collector writes activity objects, per agent and upload day (UTC):
  #   gs://<bucket>/<prefix>/conversations/<AGENT_IDENTITY_*>/dt=<YYYYMMDD>/<serial>/<email>[_<org>]/<session>/<ts>_<uuid>_logs|traces.json.gz
  prefix_slash = var.logs_prefix == "" ? "" : "${var.logs_prefix}/"
  raw_root     = "gs://${var.logs_bucket}/${local.prefix_slash}conversations/"
  # TraceForce's daily metadata snapshots + the Iceberg data live under this subtree.
  derived_root = "gs://${var.logs_bucket}/${local.prefix_slash}_traceforce/lakehouse/"
  exports_root = "${local.derived_root}exports/"
  iceberg_root = "${local.derived_root}iceberg/"

  # Only these four rails are in the standardized OTLP GenAI format (same as AWS).
  agents = {
    "AGENT_IDENTITY_CLAUDE_CODE"    = 111
    "AGENT_IDENTITY_CURSOR"         = 2
    "AGENT_IDENTITY_CLAUDE"         = 1
    "AGENT_IDENTITY_GITHUB_COPILOT" = 8
  }

  name = "traceforce-lakehouse"

  # Postgres/Iceberg type -> BigQuery type. JSON-bearing columns are already string.
  bq_type = {
    string    = "STRING"
    int       = "INTEGER"
    long      = "INTEGER"
    double    = "FLOAT"
    boolean   = "BOOLEAN"
    timestamp = "TIMESTAMP"
  }

  # agent_events schema (copied from the AWS module; identical contract). JSON-bearing
  # columns (attrs_json, resource_json, content_*, tool_args/result) are STRING here because
  # managed Iceberg forbids the JSON type.
  agent_events_schema = [
    { name = "agent", type = "string", required = true },
    { name = "agent_type", type = "int", required = true },
    { name = "device_native_id", type = "string", required = true },
    { name = "device_uuid", type = "string", required = false },
    { name = "sandbox_native_id", type = "string", required = false },
    { name = "path_email", type = "string", required = false },
    { name = "path_org", type = "string", required = false },
    { name = "path_session", type = "string", required = false },
    { name = "upload_ts", type = "timestamp", required = false },
    { name = "source_object", type = "string", required = true },
    { name = "signal", type = "string", required = true },
    { name = "user_email", type = "string", required = false },
    { name = "agent_org_id", type = "string", required = false },
    { name = "user_id", type = "string", required = false },
    { name = "session_id", type = "string", required = false },
    { name = "resource_session_id", type = "string", required = false },
    { name = "ts", type = "timestamp", required = true },
    { name = "end_ts", type = "timestamp", required = false },
    { name = "event_name", type = "string", required = false },
    { name = "span_name", type = "string", required = false },
    { name = "operation", type = "string", required = false },
    { name = "prompt_id", type = "string", required = false },
    { name = "generation_id", type = "string", required = false },
    { name = "tool_name", type = "string", required = false },
    { name = "tool_type", type = "string", required = false },
    { name = "tool_call_id", type = "string", required = false },
    { name = "mcp_server_name", type = "string", required = false },
    { name = "tool_args", type = "string", required = false },
    { name = "tool_result", type = "string", required = false },
    { name = "decision", type = "string", required = false },
    { name = "sd_enforcement", type = "string", required = false },
    { name = "containment_enforcement", type = "string", required = false },
    { name = "error_type", type = "string", required = false },
    { name = "model", type = "string", required = false },
    { name = "input_tokens", type = "long", required = false },
    { name = "output_tokens", type = "long", required = false },
    { name = "cache_read_tokens", type = "long", required = false },
    { name = "cost_usd", type = "double", required = false },
    { name = "content_input", type = "string", required = false },
    { name = "content_output", type = "string", required = false },
    { name = "service_name", type = "string", required = false },
    { name = "service_version", type = "string", required = false },
    { name = "os_type", type = "string", required = false },
    { name = "attrs_json", type = "string", required = false },
    { name = "resource_json", type = "string", required = false },
    { name = "ingested_at", type = "timestamp", required = true },
  ]

  # 17 metadata mirror tables (copied from the AWS module; identical contract).
  export_tables = {
    devices = [
      "id:string", "org_id:string", "device_native_id:string", "device_uuid:string", "friendly_name:string",
      "platform:string", "architecture:string", "os_version:string", "chip_model:string", "account_metadata:string",
      "created_at:timestamp", "updated_at:timestamp", "last_seen_at:timestamp", "deleted_at:timestamp",
    ]
    sandboxes = [
      "id:string", "org_id:string", "parent_device_id:string", "sandbox_native_id:string", "runtime_type:string",
      "workspace_folder:string", "friendly_name:string", "os_version:string", "account_metadata:string",
      "created_at:timestamp", "updated_at:timestamp", "last_seen_at:timestamp", "deleted_at:timestamp",
    ]
    agent_accounts = [
      "id:string", "org_id:string", "device_id:string", "sandbox_id:string", "agent_id:string", "agent_type:int",
      "plan:string", "tier:string", "agent_email:string", "agent_org_id:string", "security_settings:string",
      "metadata:string", "models_configuration:string", "created_at:timestamp", "updated_at:timestamp",
      "last_seen_at:timestamp", "last_active_at:timestamp", "deleted_at:timestamp",
    ]
    agent_instances = [
      "id:string", "org_id:string", "device_id:string", "sandbox_id:string", "agent_catalog_id:string",
      "agent_type:int", "agent_deployment:string", "tenant:string", "metadata:string", "configuration:string",
      "installations:string", "created_at:timestamp", "updated_at:timestamp", "last_seen_at:timestamp",
      "last_active_at:timestamp", "deleted_at:timestamp",
    ]
    agent_instances_accounts = [
      "id:string", "org_id:string", "agent_instance_id:string", "agent_account_id:string",
      "device_id:string", "sandbox_id:string", "created_at:timestamp", "updated_at:timestamp",
    ]
    device_owner_mappings = [
      "id:string", "org_id:string", "mdm_integration_id:string", "device_native_id:string",
      "owner_email:string", "owner_name:string", "created_at:timestamp", "updated_at:timestamp",
    ]
    agent_catalog = [
      "id:string", "agent_name:string", "description:string", "website:string", "logo_url:string",
      "agent_type:int", "domain:string", "created_at:timestamp", "updated_at:timestamp",
    ]
    sensitive_data_findings = [
      "id:string", "org_id:string", "device_id:string", "sandbox_id:string", "conversation_id:string", "file_id:string",
      "message_external_id:string", "message_timestamp:timestamp", "category:string", "type:string",
      "start_offset:long", "end_offset:long", "start_line:long", "end_line:long", "part_index:int",
      "rule_id:string", "encoding_type:string", "archive_inner_path:string", "finding_status:string",
      "metadata:string", "customer_storage:string", "conversation_storage:string",
      "created_at:timestamp", "updated_at:timestamp",
    ]
    connector_containment_findings = [
      "id:string", "org_id:string", "device_id:string", "sandbox_id:string", "conversation_id:string", "op:string",
      "tool_name:string", "operation:string", "tool_use_id:string", "prompt_id:string", "hook_event_name:string",
      "detected_at:timestamp", "finding_status:string", "outcome:string", "metadata:string",
      "customer_storage:string", "conversation_storage:string", "created_at:timestamp", "updated_at:timestamp",
    ]
    agent_conversations = [
      "id:string", "org_id:string", "device_id:string", "sandbox_id:string", "agent_account_id:string",
      "conversation_external_id:string", "name:string", "is_archived:boolean",
      "conversation_create_time:timestamp", "conversation_update_time:timestamp",
      "customer_storage:string", "created_at:timestamp", "updated_at:timestamp",
    ]
    agent_conversation_files = [
      "id:string", "org_id:string", "device_id:string", "sandbox_id:string", "conversation_id:string",
      "file_external_id:string", "file_name:string", "mime_type:string", "size_bytes:long",
      "message_external_id:string", "message_timestamp:timestamp", "archive_inner_path:string",
      "customer_storage:string", "created_at:timestamp", "updated_at:timestamp",
    ]
    mcp_server_instances = [
      "id:string", "org_id:string", "device_id:string", "sandbox_id:string", "agent_account_id:string",
      "mcp_server_id:string", "mcp_server_type:int", "mcp_server_location:string", "mcp_native_id:string",
      "transport_type:string", "deployment_model:string", "auth_type:string", "transport_security_type:string",
      "distribution_channel:string", "agent_type:int", "project_path:string", "linked_plans:string",
      "metadata:string", "security_findings:string", "tools:string",
      "created_at:timestamp", "updated_at:timestamp", "last_seen_at:timestamp", "deleted_at:timestamp",
    ]
    mcp_server_agent_instances = [
      "id:string", "org_id:string", "agent_instance_id:string", "mcp_server_instance_id:string",
      "device_id:string", "sandbox_id:string", "created_at:timestamp", "updated_at:timestamp",
    ]
    mcp_servers = [
      "id:string", "org_id:string", "mcp_catalog_id:string", "mcp_server_type:int",
      "active_users:int", "total_incidents:int", "active_issues:int", "affected_devices:int",
      "base_score:double", "actual_score:double", "agent_names:string", "distribution_channels:string",
      "auth_types:string", "sandbox_runtime_types:string", "instance_count:int", "has_host_instances:boolean",
      "first_seen_at:timestamp", "last_reviewed:timestamp", "created_at:timestamp", "updated_at:timestamp",
      "deleted_at:timestamp",
    ]
    mcp_catalog = [
      "id:string", "mcp_server_name:string", "description:string", "website:string", "logo_url:string",
      "mcp_server_type:int", "category_id:string", "source_type:string", "execution_environment:string",
      "authentication_methods:string", "detection_patterns:string", "created_at:timestamp", "updated_at:timestamp",
    ]
    org_mcp_catalog = [
      "id:string", "org_id:string", "mcp_server_name:string", "description:string", "website:string", "logo_url:string",
      "mcp_server_type:int", "category_id:string", "source_type:string", "execution_environment:string",
      "authentication_methods:string", "detection_patterns:string", "created_at:timestamp", "updated_at:timestamp",
    ]
    mcp_categories = [
      "id:string", "name:string", "description:string", "resource_type:string",
      "created_at:timestamp", "updated_at:timestamp",
    ]
  }

  # "name:type" -> { name, type }
  export_columns = {
    for t, cols in local.export_tables : t => [
      for c in cols : { name = split(":", c)[0], type = split(":", c)[1] }
    ]
  }

  # biglake_configuration.connection_id wants project.location.connection (location lowercased).
  connection_ref = "${local.project}.${lower(var.location)}.${google_bigquery_connection.gcs.connection_id}"

  # Rendered ingest SQL (uses the validated template + the two JS routines).
  ingest_sql = templatefile("${path.module}/sql/ingest_agent_events.sql.tftpl", {
    target          = "${local.project}.${var.dataset_id}.agent_events"
    raw             = "${local.project}.${var.dataset_id}.raw_conversations"
    dataset         = "${local.project}.${var.dataset_id}"
    agent_in_list   = join(", ", [for k in keys(local.agents) : "'${k}'"])
    agent_type_case = join(" ", [for k, v in local.agents : "WHEN '${k}' THEN ${v}"])
    cols            = join(", ", [for c in local.agent_events_schema : c.name])
    lookback_days   = var.lookback_days
  })

  # Rendered mirror SQL: one guarded atomic MERGE per table, concatenated into one daily script.
  # NOTE: this runs as ONE multi-statement script, so a runtime error on any table aborts every
  # table after it that run (unlike AWS's Step Functions Map, which isolates per-table). Each MERGE
  # is a full idempotent upsert, so the next run after the bad table is fixed catches the rest up;
  # a failed run is visible in the BigQuery scheduled-query run history.
  mirror_sql = join("\n", [
    for t, cols in local.export_columns : templatefile("${path.module}/sql/mirror_export.sql.tftpl", {
      target      = "${local.project}.${var.dataset_id}.${t}"
      source      = "${local.project}.${var.dataset_id}.export_${t}"
      cols        = join(", ", [for c in cols : c.name])
      update_set  = join(", ", [for c in cols : "${c.name} = s.${c.name}" if c.name != "id"])
      insert_vals = join(", ", [for c in cols : "s.${c.name}"])
    })
  ])
}
