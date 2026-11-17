# enforcement_events

One row per thing TraceForce's hook enforced on a prompt or tool call (block/warn), recorded authoritatively at the decision. Append-only audit ledger, NOT a finding and NOT an incident; it never feeds the incidents pipeline. Use it for enforcement effectiveness ('what did we prevent'), not detection counts. A blocked prompt never produces a sensitive_data_findings row; this is where it is recorded.

Joins:
- person/session (identity enrichment, may be unresolved): the ledger is identity-less, so LEFT JOIN agent_conversations on (org_id, device_id, conversation_external_id) — but resolve identity ONLY when exactly one row matches. The same conversation_external_id can exist under two agent_account_id on a device (agent_conversations is unique on (org_id, agent_account_id, conversation_external_id)), so match via a scalar/aggregated subquery (or a GROUP BY that keeps one enforcement row) to avoid fanning out and double-counting enforcement, and leave the person NULL when >1 candidate matches or the conversation row is absent. Then agent_conversations.agent_account_id → agent_accounts.agent_email
- device owner (for display): device_id → devices.device_native_id → device_owner_mappings.owner_email
- agent name: agent → agent_catalog.agent_type (the ledger's agent is the AgentIdentity decoded to text, same vocabulary as agent_catalog.agent_type)
- the enforced tool call: tool_use_id = agent_events.tool_call_id (same session) on tool-call surfaces; for prompt surfaces the turn is message_external_id (Claude prompt id / Cursor generation id; absent for Codex/Copilot)

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, record_id): one row per hook enforcement; a redelivered upload no-ops
- (org_id, correlation_id) WHERE action = 4: one allowed_after_warn override per operation (repeats within the deny-once TTL collapse)

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `device_id` | string | → devices.id |
| `sandbox_id` | string | → sandboxes.id; NULL when the row is about the host device itself. |
| `conversation_external_id` | string | The agent's own session id the hook stamped; equals agent_events.session_id and agent_conversations.conversation_external_id. Stored as text, NOT a foreign key: the ledger records the attempt whether or not the conversation row exists yet. |
| `record_id` | string | The hook's per-enforcement id; the ledger's dedup key (unique per (org_id, record_id)). A redelivered upload no-ops. |
| `agent` | string | Which agent product the enforcement was for (decoded AgentIdentity text, e.g. 'claude_code'). |
| `control` | string | Which control decided, as text: 'containment' / 'sensitive_data' / 'mcp_access' / 'mcp_tool_permission'. |
| `surface` | string | What it applied to, as text: 'tool_call' / 'file_read' / 'prompt' / 'prompt_file'. |
| `mode` | string | The policy mode, as text: 'block' or 'warn'. |
| `action` | string | What actually happened, as text: 'deny' (block: denied), 'ask' (warn: the agent's own dialog asked), 'deny_once' (warn: withheld until the user re-submitted), 'allowed_after_warn' (warn: re-submitted, so let through). The Prevented view EXCLUDES 'allowed_after_warn' AND any 'deny_once' whose (org_id, correlation_id) has a matching 'allowed_after_warn' (the user overrode it — see correlation_id); otherwise an overridden warn is over-counted as prevented. |
| `tool_name` | string | The tool the call used (e.g. 'Bash'); '' for a prompt enforcement. |
| `tool_use_id` | string | The agent's tool-call id for a tool enforcement; equals agent_events.tool_call_id. NULL for prompt enforcements and for Cursor (which carries no per-tool-call id). |
| `message_external_id` | string | The agent's prompt/turn id for a prompt enforcement (Claude prompt id, Cursor generation id); NULL for Codex/Copilot (no prompt id) and for tool-call enforcements. |
| `correlation_id` | string | Stable per-operation key (the deny-once op hash) the hook stamps on every record for the same operation. Identical on a deny_once and the allowed_after_warn that overrode it, so Prevented counts a deny_once ONLY when no allowed_after_warn shares its (org_id, correlation_id). Content-based, so it works for Cursor. NULL when the hook input had no hashable operation. |
| `risky_action_subcategory` | string | The containment risky-action subcategory, as text (same vocabulary as connector_containment_findings.risky_action_subcategory); 'unknown' on sensitive-data rows. |
| `sensitive_data_category` | string | The sensitive-data category, as text (same vocabulary as sensitive_data_findings.category, e.g. 'credentials'); 'unknown' on containment rows. |
| `rule_id` | string | The detector/rule that fired (sensitive-data only, e.g. a gitleaks rule id or a custom-regex rule id); NULL for containment, which has no discrete rule. |
| `description` | string | The sanitized, user-facing reason shown at the block/warn: it starts with the [Traceforce - Blocked] / [Traceforce - Action Required] tag and names the data types or the risky action. Commands are redacted and no secret value is included. NULL on an 'allowed_after_warn' override (nothing was prevented). |
| `detected_at` | timestamp | When the hook enforced the attempt (UTC); bound periods on this, not created_at. |
| `customer_storage` | string | JSON text: a pointer into the customer's BYO storage bucket; provider is 'gcs', 's3' or 'azure_blob'. On conversations it locates the session's uploaded activity objects; on findings it locates the evidence object holding the verbatim matched value / tool input. NULL when BYO storage is unconfigured or the source object is empty. Evidence is not in the lake by design; see reference/redaction.md. |
| `created_at` | timestamp | Row created (UTC). |
