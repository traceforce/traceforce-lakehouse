# connector_containment_findings

One row per risky write/delete a tool attempted through a connector (Bash, Shell, MCP). Denied attempts are NOT stored; only executed/failed ones.

Joins:
- person: conversation_id → agent_conversations.agent_account_id → agent_accounts (no deleted_at filter); device owner via device_id → devices → device_owner_mappings
- tool_use_id = agent_events.tool_call_id (same session); the tool_decision row carries the approval source. Cursor rows carry no tool_decision, so join tool_use_id to its postToolUse row instead
- conversation_id → agent_conversations.id → agent_events.session_id

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, conversation_id, tool_use_id): one row per tool call

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `device_id` | string | → devices.id |
| `sandbox_id` | string | → sandboxes.id; NULL when the row is about the host device itself. |
| `conversation_id` | string | → agent_conversations.id |
| `op` | string | Kind of mutation: 'write' or 'delete' (never NULL). |
| `tool_name` | string | The agent's shell tool (e.g. `Bash`, `Shell`) or `MCP:<server>`. |
| `operation` | string | Display-safe subject of the op: an MCP tool's bare name, or a file path, redacted and truncated to 512 bytes; '' for shell ops (Bash/Shell); the command itself is in the joined agent_events.tool_args. |
| `tool_use_id` | string | Agent's tool-call id; equals agent_events.tool_call_id. |
| `prompt_id` | string | Always NULL here; take prompt_id from the joined agent_events row (tool_use_id = tool_call_id). |
| `hook_event_name` | string | The agent's own event name for the record that observed it (varies by agent, e.g. `tool_result`, `postToolUse`). |
| `detected_at` | timestamp | When the op was observed (UTC); bound periods on this, not created_at. |
| `finding_status` | string | Reviewer triage state as text (same set as sensitive_data_findings.finding_status); never NULL, starts 'awaiting_review'. |
| `outcome` | string | Execution result as text ('executed' / 'failed' / 'unspecified'); never NULL. |
| `risky_action_category` | string | Grouping of the risky action, as text: 'company_data_or_infra_destroyed' / 'company_systems_changed' / 'device_defenses_disabled_or_wiped' / 'device_or_dev_env_changed'; 'unknown' on rows from older scouts. |
| `risky_action_subcategory` | string | The specific risky action, as text, grouped by category — destroyed: 'shared_db_destroyed' / 'cloud_infra_destroyed' / 'connector_records_deleted'; changed: 'cloud_resources_changed' / 'shared_db_written' / 'shared_repo_history' / 'connector_records_written' / 'connector_commands_run'; device defenses: 'core_protection_off' / 'device_wiped' / 'downloaded_code_run' / 'protection_loosened'; device or dev environment: 'processes_services_stopped' / 'device_settings_changed' / 'software_installed' / 'local_work_discarded' / 'local_db_changed' / 'local_connector_writes'; 'unknown' on rows from older scouts. |
| `metadata` | string | JSON text; reviewer close tracking {statusComment, statusUpdatedAt, statusUpdatedBy}; '{}' or NULL until a reviewer closes the finding. |
| `customer_storage` | string | JSON text {bucket, key_prefix, region, provider, source_file}: a pointer into the customer's BYO storage bucket; provider is a code, not a name (1 = GCS, 2 = S3, 3 = Azure Blob). On conversations it locates the session's uploaded activity objects; on findings it locates the evidence object holding the verbatim matched value / tool input (the redacted attachment for file findings). NULL when BYO storage is unconfigured or the source object is empty. Evidence is not in the lake by design; see reference/redaction.md. |
| `conversation_storage` | string | JSON text {bucket, key_prefix, region, provider, source_file}: a pointer into the customer's BYO storage bucket — the exact activity/source object the finding was detected in. Equals agent_events.source_object, the object's storage URI (`s3://…` on AWS, `gs://…` on GCP; = concat(scheme, '://', bucket, '/', key_prefix, source_file)); join on it to get the records of that upload. Only source_file under 'telemetry/' is in the lake; 'conversations/' pointers (browser captures and older uploads) match zero rows. NULL when BYO storage is unconfigured or the finding's source object is empty. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
