# agents

Org-level rollup per agent and plan: counts and scores. One row per (agent_type, plan) per org.

Joins:
- agents.agent_type = agent_catalog.agent_type (product name; agent_catalog_id may be NULL)
- agent_accounts.agent_id = agents.id
- Its counts are over agent_issues with the same agent_type and plan

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, agent_type, plan): one rollup per agent and plan per org

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `agent_catalog_id` | string | → agent_catalog.id (FK); may be NULL, join agent_catalog on agent_type instead. |
| `agent_type` | string | Which agent product. |
| `plan` | string | Account plan as text, same vocabulary as agent_accounts.plan; 'unknown' for installs with no signed-in account. |
| `active_users` | int | Distinct active devices (not users) with this agent and plan; 0 or NULL when none. |
| `total_incidents` | int | Count of open agent_issues rows for this agent and plan (not deduped by type); 0 or NULL when none are open. |
| `active_issues` | int | Count of distinct open issue types; 0 or NULL when none are open. |
| `affected_devices` | int | Count of distinct devices with an open issue; 0 or NULL when none. |
| `base_score` | double | Baseline risk score (0-100) for the agent and plan; NULL (not 0) when no baseline scores exist yet. |
| `actual_score` | double | Risk score (0-100) from your org's usage; NULL (not 0) when no scores for this org, agent and plan yet. |
| `deployment_types` | string | JSON array of the distinct agent_deployment values of live installs, same vocabulary as agent_instances.agent_deployment; NULL when none. |
| `sandbox_runtime_types` | string | JSON array of the distinct runtime types of the sandboxes live installs run in, same vocabulary as sandboxes.runtime_type; '[]' when none run in a sandbox. |
| `instance_count` | int | Count of distinct live installs; 0 or NULL when none. |
| `has_host_instances` | boolean | Any install on a host (not only sandboxes). |
| `first_seen_at` | timestamp | First observed (UTC). |
| `last_active_at` | timestamp | Most recent activity (UTC); NULL if never active. |
| `last_reviewed` | timestamp | Last reviewed (UTC). Always NULL. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
| `deleted_at` | timestamp | Set when no live install remains. NULL = live. |
