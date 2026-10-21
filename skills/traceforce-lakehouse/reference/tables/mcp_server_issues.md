# mcp_server_issues

One row per MCP server issue: an issue type raised on one MCP server instance, open or closed.

Joins:
- issue_type_control_id → issue_type_controls.id → issue_types.id, as for agent_issues
- mcp_server_instance_id → mcp_server_instances.id (no deleted_at filter)
- mcp_server_type → mcp_catalog.mcp_server_type or org_mcp_catalog.mcp_server_type (product name)
- The console's issue lists show issues that have a device_id and whose issue type has applicable_to = 'instance'

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, device_id, sandbox_id, mcp_server_instance_id, issue_type_control_id), NULLs compared as equal

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `mcp_server_instance_id` | string | → mcp_server_instances.id |
| `device_id` | string | → devices.id |
| `sandbox_id` | string | → sandboxes.id; NULL when the row is about the host device itself. |
| `issue_type_control_id` | string | → issue_type_controls.id |
| `mcp_server_type` | int | Integer product code; LEFT JOIN the catalogs for the name. |
| `issue_status` | string | 'active' / 'resolved' / 'dismissed' ('unknown' = unset). Open, as the console counts it, is 'active' on an 'instance' issue type. |
| `metadata` | string | JSON text, same keys as agent_issues.metadata. |
| `last_seen_at` | timestamp | Most recent scan that still raised the issue (UTC). |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
