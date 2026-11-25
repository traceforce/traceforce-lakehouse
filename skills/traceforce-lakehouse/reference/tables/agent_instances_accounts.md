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
| `last_seen_at` | timestamp | Most recent scan that reported this link (UTC); older than the install's last_seen_at = not in the install's latest scan. Links not reported since the column was added (2026-11-05 or shortly after) carry that one backfill timestamp, not their real last report. Not for agent_deployment = 'browser', whose profiles scan separately into one install. |
| `deleted_at` | timestamp | Soft delete. NULL = live. Set when a scan shows the install, MCP server or sign-in is gone, or after 7 days of scans that no longer report the link. A later report clears it. Also set when its device (or sandbox) is deleted. Set at once, to the install's last_seen_at, when the install's unknown_plan_reason becomes 'cloud' or 'api_key'. |
