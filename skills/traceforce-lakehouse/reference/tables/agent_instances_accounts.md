# agent_instances_accounts

Junction: which account is signed in through which install.

Joins:
- agent_instance_id → agent_instances.id
- agent_account_id → agent_accounts.id
- A link is live when its deleted_at IS NULL and both parents are live: agent_instances.deleted_at IS NULL AND agent_accounts.deleted_at IS NULL

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
| `last_seen_at` | timestamp | Most recent scan that reported this link (UTC). A scan sets it to the same value as the install's agent_instances.last_seen_at, so a live link with an older last_seen_at than its install was not in the install's latest scan. Not for agent_deployment = 'browser': each browser profile scans separately but shares the install, so every live link is current. |
| `deleted_at` | timestamp | Soft delete. NULL = live. An unreported link stays live until its last_seen_at is 2 weeks behind its device's (or sandbox's) last_seen_at, then is set. A later report clears it and refreshes last_seen_at. |
