# agent_instances

Installs: one row per device, agent, form factor and OS user (browser: per web domain). Includes agents that never produce an account.

Joins:
- agent_instances.device_id = devices.id AND agent_instances.agent_type = agent_events.agent_type
- agent_instances_accounts links an install to the accounts signed in through it

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, device_id, sandbox_id, tenant, agent_type, agent_deployment): one install per form factor and OS user (browser: per web domain)

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `device_id` | string | → devices.id |
| `sandbox_id` | string | → sandboxes.id; NULL when the row is about the host device itself. |
| `agent_catalog_id` | string | → agent_catalog.id (FK); may be NULL — join agent_catalog on agent_type instead. |
| `agent_type` | string | Which agent product. |
| `agent_deployment` | string | Form factor of this install, as text ('desktop_app' / 'vscode_extension' / 'cli' / 'browser' / 'ai_browser' / 'service' / 'unknown'). |
| `tenant` | string | OS-level user (uid on macOS/Linux, SID on Windows) the install belongs to; for agent_deployment = 'browser' it is the agent's web domain instead. OS user: reference/identity.md. |
| `metadata` | string | JSON text; how the install was identified: identifier, store_id, heuristic_match_method, heuristic_url, store_error; uid on browser installs (the OS user key). auth_method and model_host_raw are the raw sign-in method and model provider the agent saved locally; prefer model_host over model_host_raw. |
| `configuration` | string | JSON text; always '{}'. |
| `installations` | string | JSON text {installations: [{name, path, version}, …]}; '{}' when agent_deployment = 'browser'. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
| `last_seen_at` | timestamp | Most recent check-in that observed this row (UTC). |
| `last_active_at` | timestamp | Most recent activity (UTC); NULL if never active. |
| `deleted_at` | timestamp | Soft delete. NULL = live. Filter `deleted_at IS NULL` for the current inventory. |
| `unknown_plan_reason` | string | Why the install's plan is unknown, as text ('not_supported' / 'no_account_found' / 'plan_not_shared' / 'api_key' / 'account_unreadable' / 'org_not_found' / 'no_sign_in' / 'cloud' / 'usage_billed'); never NULL, 'unknown' = no reason reported. Meaningful only where the install's plan is unknown: reference/identity.md. |
| `model_host` | string | Cloud platform serving the agent's models, as text ('aws_bedrock' / 'gcp_vertex' / 'unknown'); never NULL. Filled only for filesystem installs; browser installs are always 'unknown'. |
