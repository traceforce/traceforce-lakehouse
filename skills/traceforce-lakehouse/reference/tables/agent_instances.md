# agent_instances

Installs: one row per (device, agent, deployment form factor, OS user). Includes agents that never produce an account (Copilot).

Joins:
- agent_instances.device_id = devices.id AND agent_instances.agent_type = agent_events.agent_type
- agent_instances_accounts links an install to the accounts signed in through it

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, device_id, sandbox_id, tenant, agent_type, agent_deployment): one install per OS user and form factor

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `device_id` | string | → devices.id |
| `sandbox_id` | string | → sandboxes.id; NULL when the row is about the host device itself. |
| `agent_catalog_id` | string | → agent_catalog.id |
| `agent_type` | int | Which agent product. |
| `agent_deployment` | string | Form factor of this install, as text ('desktop_app' / 'vscode_extension' / 'cli' / 'browser' / 'ai_browser' / 'service' / 'unknown'). |
| `tenant` | string | OS-level user (uid on macOS/Linux, SID on Windows) the install belongs to; resolve to a username via devices.account_metadata. |
| `metadata` | string | JSON text; how the install was identified: identifier, store_id, heuristic_match_method, heuristic_url, store_error. |
| `configuration` | string | JSON text; detected agent configuration. |
| `installations` | string | JSON text; filesystem installation records (paths, versions). |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
| `last_seen_at` | timestamp | Most recent check-in that observed this row (UTC). |
| `last_active_at` | timestamp | Most recent activity (UTC); NULL if never active. |
| `deleted_at` | timestamp | Soft delete. NULL = live. Filter `deleted_at IS NULL` for the current inventory. |
