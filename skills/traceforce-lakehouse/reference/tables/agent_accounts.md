# agent_accounts

One row per signed-in account: (device, agent, email, vendor org). Who is behind an event.

Joins:
- agent_accounts.device_id = devices.id AND agent_accounts.agent_type = agent_events.agent_type AND lower(agent_accounts.agent_email) = lower(agent_events.user_email) (enrichment of an event with plan / vendor org; the person is already user_email)
- agent_accounts.agent_org_id = agent_events.agent_org_id when both are non-NULL (Claude family)
- When reached by id from agent_conversations.agent_account_id, do NOT filter deleted_at: a signed-out account still owns its past findings (this is what the console does)

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, device_id, sandbox_id, agent_type, agent_email, agent_org_id), NULLs compared as equal: the same email can have one row per device, per agent, per vendor org

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `device_id` | string | → devices.id |
| `sandbox_id` | string | → sandboxes.id; NULL when the row is about the host device itself. |
| `agent_id` | string | → the org-level agent rollup (not exported in v1). |
| `agent_type` | int | Which agent product. Codes: `AgentIdentity (lake agents)` in ../enums.md. |
| `plan` | int | Account plan. The console's notion of an agent is an INSTALL's (agent_type, coalesce(plan, 0)): start from agent_instances, LEFT JOIN agent_instances_accounts and agent_accounts; installs with no signed-in account are plan 0. Never count agents from agent_accounts alone. Codes: `AgentPlanType` in ../enums.md. |
| `tier` | string | Vendor plan tier text when known. |
| `agent_email` | string | Email the user authenticated to the agent with. Stored byte-exact; lower() is a tolerance. |
| `agent_org_id` | string | The vendor's workspace/org id (Anthropic org for Claude); NULL for Cursor/Copilot. |
| `security_settings` | string | JSON text; vendor security settings observed for the account. |
| `metadata` | string | JSON text; vendor-specific extras (e.g. version). |
| `models_configuration` | string | JSON text; models configured for the account. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
| `last_seen_at` | timestamp | Most recent check-in that observed this row (UTC). |
| `last_active_at` | timestamp | Most recent activity (UTC); NULL if never active. |
| `deleted_at` | timestamp | Soft delete. NULL = live. Filter `deleted_at IS NULL` for the current inventory. |
