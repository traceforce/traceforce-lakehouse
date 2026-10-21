# issue_type_controls

Your org's link from an issue to its issue type: one row per issue type in your org.

Joins:
- agent_issues.issue_type_control_id or mcp_server_issues.issue_type_control_id = issue_type_controls.id
- issue_type_id → issue_types.id

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, issue_type_id)

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `issue_type_id` | string | → issue_types.id |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
