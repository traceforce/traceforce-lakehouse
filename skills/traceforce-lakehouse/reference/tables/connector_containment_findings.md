# connector_containment_findings

One row per risky write/delete a tool attempted through a connector (Bash, Shell, MCP). Denied attempts are NOT stored; only executed/failed ones.

Joins:
- person: conversation_id → agent_conversations.agent_account_id → agent_accounts (no deleted_at filter); device owner via device_id → devices → device_owner_mappings
- tool_use_id = agent_events.tool_call_id (same session); the tool_decision row carries the approval source. Cursor rows carry no tool_decision, so join tool_use_id to the finding's tool_result/span row instead
- conversation_id → agent_conversations.id → agent_events.session_id
- device_id → devices.id
- conversation_storage pointer → agent_events.source_object (the exact uploaded object)

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, conversation_id, tool_use_id): one row per tool call

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `device_id` | string | → devices.id |
| `sandbox_id` | string | → sandboxes.id; NULL when the row is about the host device itself. |
| `conversation_id` | string | → agent_conversations.id |
| `op` | string | Kind of mutation: always 'write' or 'delete' (never NULL; denied/unknown are filtered out). |
| `tool_name` | string | Tool that attempted it: 'Bash', 'Shell' (Cursor) or 'MCP:<server>'; never a built-in file tool (Write/Edit). |
| `operation` | string | Display-safe subject of the op: an MCP tool's bare name, or a file path, redacted and truncated to 512 bytes; '' (empty string) for shell/command ops (Bash/Shell); the verbatim command never lands here, only in customer_storage — read the actual tool input from the joined agent_events.tool_args. |
| `tool_use_id` | string | Agent's tool-call id; equals agent_events.tool_call_id. |
| `prompt_id` | string | Id of the prompt/turn that triggered the op, but this table does not populate it (NULL here) — do not filter or aggregate this column. It matches agent_events.prompt_id, so reach the triggering turn (the prompt plus its sibling tool calls) by joining tool_use_id → agent_events.tool_call_id and using that row's prompt_id. |
| `hook_event_name` | string | Event name of the record that observed it: 'tool_result' / 'tool_decision' (Claude-family) or 'postToolUse' / 'postToolUseFailure' (Cursor). |
| `detected_at` | timestamp | When the op was observed (UTC); the reliable order-by time for containment findings; effectively always set. |
| `finding_status` | string | Reviewer triage state as text (same set as sensitive_data_findings.finding_status); never NULL, starts 'awaiting_review'. |
| `outcome` | string | Execution result as text ('executed' / 'failed' / 'unspecified'); never NULL, never 'denied' (denied attempts aren't stored). |
| `risky_action_category` | string | Grouping of the risky action, as text: 'company_data_or_infra_destroyed' / 'company_systems_changed' / 'device_defenses_disabled_or_wiped' / 'device_or_dev_env_changed'; 'unknown' on rows from older scouts (no taxonomy). Derived from risky_action_subcategory. |
| `risky_action_subcategory` | string | The specific risky action, as text, grouped by category — destroyed: 'shared_db_destroyed' / 'cloud_infra_destroyed' / 'connector_records_deleted'; changed: 'cloud_resources_changed' / 'shared_db_written' / 'shared_repo_history' / 'connector_records_written' / 'connector_commands_run'; device defenses: 'core_protection_off' / 'device_wiped' / 'downloaded_code_run' / 'protection_loosened'; device or dev environment: 'processes_services_stopped' / 'device_settings_changed' / 'software_installed' / 'local_work_discarded' / 'local_db_changed' / 'local_connector_writes'; 'unknown' on rows from older scouts. |
| `metadata` | string | JSON text; reviewer close tracking {statusComment, statusUpdatedAt, statusUpdatedBy}; '{}' or NULL until a reviewer closes the finding. |
| `customer_storage` | string | JSON text {bucket, key_prefix, region, provider, source_file}: a pointer into the customer's BYO storage bucket; provider is a code, not a name (1 = GCS, 2 = S3, 3 = Azure Blob). On conversations it locates the session's uploaded activity objects; on findings it locates the evidence object holding the verbatim matched value / tool input (the redacted attachment for file findings). NULL when BYO storage is unconfigured or the source object is empty. Evidence is not in the lake by design; see reference/redaction.md. |
| `conversation_storage` | string | JSON text {bucket, key_prefix, region, provider, source_file}: a pointer into the customer's BYO storage bucket — the exact activity/source object the finding was detected in. Equals agent_events.source_object, the object's storage URI (`s3://…` on AWS, `gs://…` on GCP; = concat(scheme, '://', bucket, '/', key_prefix, source_file)); join on it to get the records of that upload. Only source_file under 'telemetry/' is in the lake; 'conversations/' pointers (browser captures and older uploads) match zero rows. NULL when BYO storage is unconfigured or the finding's source object is empty. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
