# connector_containment_findings

One row per write/delete a tool attempted through a connector (MCP, Bash, Write). Denied attempts are NOT stored; only executed/failed ones.

Joins:
- person: conversation_id → agent_conversations.agent_account_id → agent_accounts (no deleted_at filter); device owner via device_id → devices → device_owner_mappings
- tool_use_id = agent_events.tool_call_id (same session). Claude family only: Cursor emits no tool_decision, read the finding's own outcome and the postToolUseFailure row with the same tool_call_id
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
| `op` | string | Kind of mutation attempted. |
| `tool_name` | string | Tool that attempted it (Write, Bash, MCP:<server>). |
| `operation` | string | The MCP tool name (e.g. execute_sql) or the risky statement; empty for non-MCP tools. |
| `tool_use_id` | string | Agent's tool-call id; equals agent_events.tool_call_id. |
| `prompt_id` | string | Hook prompt id. |
| `hook_event_name` | string | Hook that observed it (e.g. PreToolUse). |
| `detected_at` | timestamp | When detected (UTC). |
| `finding_status` | string | Reviewer triage state. |
| `outcome` | string | Execution result. Never 'denied' in the table. |
| `metadata` | string | JSON text; vendor-specific extras (e.g. version). |
| `customer_storage` | string | JSON text {bucket, key_prefix, region, provider, source_file}: a pointer into customer S3. On conversations it locates the session's uploaded activity objects; on findings it locates the evidence object holding the verbatim matched value / tool input (the redacted attachment for file findings). Evidence is not in the lake by design; see SKILL.md Redaction and evidence. |
| `conversation_storage` | string | JSON text {bucket, key_prefix, region, provider, source_file}: the exact activity object the finding was detected in. Equals agent_events.source_object when written as concat('s3://', bucket, '/', key_prefix, source_file); join on it to get the records of that upload. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
