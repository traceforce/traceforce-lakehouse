# TraceForce's control-plane metadata, mirrored into the same S3 Tables namespace so
# Claude can join it against agent_events with plain SQL. v1 = 17 tables: identity
# (devices, sandboxes, accounts, installs and their junction, MDM owners), agent names,
# the two finding types with their bridges to the logs (conversations, files), and the
# whole MCP chain (instances, junction to installs, rollups, global + org catalogs,
# categories).
# Deferred until a customer question needs them: user groups and IdP users, issues and
# policies (each comes with its lookup chain).
#
# Flow: a TraceForce job (TraceForce's export job) writes one full
# snapshot per table per day as gzipped JSON Lines to
#   ${exports_root}<table>/dt=YYYY-MM-DD/<HHMMSS>.jsonl.gz
# under the same TraceForce role your Storage Provider grant already trusts; the job only
# creates new keys, it never overwrites or deletes. The daily "exports" run of the state machine MERGEs the newest
# snapshot into the Iceberg table and deletes rows that vanished from it, so the Iceberg
# table always equals the last snapshot. Old snapshots are the customer's to expire.
#
# One column list per table drives three things: the Glue source table (all strings,
# parsed from JSON), the Iceberg target table (typed), and the CASTs in the MERGE SQL.
# Postgres -> Iceberg: uuid/text -> string, integer -> int, bigint -> long,
# boolean -> boolean, timestamptz -> timestamp (UTC), numeric -> double, jsonb/array -> string.
locals {
  export_tables = {
    # --- identity ---
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
    # --- agent names (global) ---
    agent_catalog = [
      "id:string", "agent_name:string", "description:string", "website:string", "logo_url:string",
      "agent_type:int", "domain:string", "created_at:timestamp", "updated_at:timestamp",
    ]
    # --- findings and their bridge to the logs ---
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
    # --- MCP: instances, links to installs, rollups, catalogs ---
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
}

# Source: the newest JSONL snapshot, read as strings and CAST in SQL.
resource "aws_glue_catalog_table" "export_src" {
  for_each = local.export_columns

  name          = "export_${each.key}"
  database_name = aws_glue_catalog_database.lakehouse.name
  table_type    = "EXTERNAL_TABLE"
  description   = "TraceForce daily snapshot of ${each.key} (JSON Lines). Mirror source only; query the Iceberg table ${each.key} instead."

  parameters = {
    EXTERNAL                      = "TRUE"
    "projection.enabled"          = "true"
    "projection.dt.type"          = "date"
    "projection.dt.format"        = "yyyy-MM-dd"
    "projection.dt.range"         = "2026-09-01,NOW"
    "projection.dt.interval"      = "1"
    "projection.dt.interval.unit" = "DAYS"
    "storage.location.template"   = "${local.exports_root}${each.key}/dt=$${dt}/"
  }

  storage_descriptor {
    location      = "${local.exports_root}${each.key}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    dynamic "columns" {
      for_each = each.value
      content {
        name = columns.value.name
        type = "string"
      }
    }

    # No ignore.malformed.json: a malformed line must fail that table's MERGE loudly rather
    # than be dropped, because the DELETE step would then remove the rows it stood for.
    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
    }
  }

  partition_keys {
    name = "dt"
    type = "string"
  }
}

# Target: typed Iceberg table, same name as in TraceForce.
resource "aws_s3tables_table" "export" {
  for_each = local.export_columns

  name             = each.key
  namespace        = aws_s3tables_namespace.tf.namespace
  table_bucket_arn = aws_s3tables_table_bucket.lakehouse.arn
  format           = "ICEBERG"

  metadata {
    iceberg {
      schema {
        dynamic "field" {
          for_each = each.value
          content {
            name     = field.value.name
            type     = field.value.type
            required = field.value.name == "id"
          }
        }
      }
    }
  }
}

locals {
  # MERGE + DELETE statements per table, rendered once and embedded in the state machine.
  export_sql = {
    for t, cols in local.export_columns : t => {
      merge = templatefile("${path.module}/sql/mirror_export_merge.sql.tftpl", {
        target  = "\"s3tablescatalog/${aws_s3tables_table_bucket.lakehouse.name}\".\"${aws_s3tables_namespace.tf.namespace}\".\"${t}\""
        source  = "\"${aws_glue_catalog_database.lakehouse.name}\".\"export_${t}\""
        columns = cols
      })
      delete = templatefile("${path.module}/sql/mirror_export_delete.sql.tftpl", {
        target = "\"s3tablescatalog/${aws_s3tables_table_bucket.lakehouse.name}\".\"${aws_s3tables_namespace.tf.namespace}\".\"${t}\""
        source = "\"${aws_glue_catalog_database.lakehouse.name}\".\"export_${t}\""
      })
    }
  }
}
