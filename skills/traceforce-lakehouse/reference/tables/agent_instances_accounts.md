# agent_instances_accounts

Junction: which account is signed in through which install.

Joins:
- agent_instance_id → agent_instances.id
- agent_account_id → agent_accounts.id
- No deleted_at of its own. A link is live only when BOTH parents are: agent_instances.deleted_at IS NULL AND agent_accounts.deleted_at IS NULL (the console's active_agent_instances_accounts view)

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, device_id, sandbox_id, agent_instance_id, agent_account_id)

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `agent_instance_id` | string | → agent_instances.id |
| `agent_account_id` | string | → agent_accounts.id |
| `device_id` | string | → devices.id |
| `sandbox_id` | string | → sandboxes.id; NULL when the row is about the host device itself. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
