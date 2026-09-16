# connector_containment_findings

One row per write/delete a tool attempted through a connector (MCP, Bash, Write). Denied attempts are NOT stored; only executed/failed ones.

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
| `tool_name` | string | Tool that attempted it (Write, Bash, MCP:<server>). |
| `operation` | string | Display-safe subject of the op (file path or truncated tool target); '' (empty string) for decision-only rows; never the verbatim command — that lives in customer_storage; read the actual command from the joined agent_events.tool_args. |
| `tool_use_id` | string | Agent's tool-call id; equals agent_events.tool_call_id. |
| `prompt_id` | string | Hook prompt id. |
| `hook_event_name` | string | Hook that observed it (e.g. PreToolUse). |
| `detected_at` | timestamp | When the op was observed (UTC); the reliable order-by time for containment findings; effectively always set. |
| `finding_status` | string | Reviewer triage state as text (same set as sensitive_data_findings.finding_status); never NULL, starts 'awaiting_review'. |
| `outcome` | string | Execution result as text ('executed' / 'failed' / 'unspecified'); never NULL, never 'denied' (denied attempts aren't stored). |
| `metadata` | string | JSON text; vendor-specific extras (e.g. version). |
| `customer_storage` | string | JSON text {bucket, key_prefix, region, provider, source_file}: a pointer into the customer's BYO storage bucket. On conversations it locates the session's uploaded activity objects; on findings it locates the evidence object holding the verbatim matched value / tool input (the redacted attachment for file findings). NULL when BYO storage is unconfigured or the source object is empty. Evidence is not in the lake by design; see SKILL.md Redaction and evidence. |
| `conversation_storage` | string | JSON text {bucket, key_prefix, region, provider, source_file}: a pointer into the customer's BYO storage bucket — the exact activity/source object the finding was detected in. Equals agent_events.source_object when written as concat('s3://', bucket, '/', key_prefix, source_file); join on it to get the records of that upload. NULL when BYO storage is unconfigured or the finding's source object is empty. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
