# agent_instances_accounts

Junction: which account is signed in through which install.

Joins:
- agent_instance_id → agent_instances.id
- agent_account_id → agent_accounts.id
- A link is live when its own deleted_at IS NULL and BOTH parents are live: agent_instances.deleted_at IS NULL AND agent_accounts.deleted_at IS NULL. Check the parents too: a link's deleted_at can stay NULL after a parent is deleted, and reads NULL until the export carries it

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
| `last_seen_at` | timestamp | Most recent check-in that observed this row (UTC). |
| `deleted_at` | timestamp | Soft delete. NULL = live. Filter `deleted_at IS NULL` for the current inventory. |
