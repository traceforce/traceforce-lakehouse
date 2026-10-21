# agent_issues

One row per agent issue: an issue type raised on one install, account or cloud agent, open or closed.

Joins:
- issue_type_control_id → issue_type_controls.id → issue_type_controls.issue_type_id → issue_types.id (name, score, criticality); see reference/joins.md
- agent_instance_id → agent_instances.id, agent_account_id → agent_accounts.id, device_id → devices.id (no deleted_at filter: a removed install still owns its past issues)
- The console's issue lists show issues that have a device_id and whose issue type has applicable_to = 'instance'

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, device_id, sandbox_id, agent_instance_id, agent_account_id, issue_type_control_id), NULLs compared as equal
- (org_id, cloud_agent_id, issue_type_control_id) when cloud_agent_id is set

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `agent_instance_id` | string | → agent_instances.id; NULL when the issue is not about one install. |
| `device_id` | string | → devices.id |
| `sandbox_id` | string | → sandboxes.id; NULL when the row is about the host device itself. |
| `agent_account_id` | string | → agent_accounts.id; NULL when the issue is not about one account. |
| `cloud_agent_id` | string | The cloud agent the issue is about (that table is not in the lake); set only on cloud-agent issues, which have no device_id. |
| `issue_type_control_id` | string | → issue_type_controls.id |
| `agent_type` | string | Which agent product. |
| `plan` | string | Account plan as text, same vocabulary as agent_accounts.plan. |
| `issue_status` | string | 'active' / 'resolved' / 'dismissed' ('unknown' = unset). Open, as the console counts it, is 'active'. |
| `metadata` | string | JSON text, camelCase keys set as the issue changes: resolutionReason ('issue_resolved' / 'entity_deleted') and resolvedAt; dismissalReason ('false_positive' / 'risk_accepted' / 'other'), dismissalComment, dismissedBy (the console user's email) and dismissedAt; reopenedBy and reopenedAt. '{}' or NULL before any of these. |
| `last_seen_at` | timestamp | Most recent scan that still raised the issue (UTC). |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
