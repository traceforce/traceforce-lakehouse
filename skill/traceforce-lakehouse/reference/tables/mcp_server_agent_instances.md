# mcp_server_agent_instances

Junction: which install (agent_instances) an MCP server instance is configured in.

Joins:
- agent_instance_id → agent_instances.id
- mcp_server_instance_id → mcp_server_instances.id
- No deleted_at of its own. A link is live only when BOTH parents are: agent_instances.deleted_at IS NULL AND mcp_server_instances.deleted_at IS NULL

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, device_id, sandbox_id, agent_instance_id, mcp_server_instance_id)

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `agent_instance_id` | string | → agent_instances.id |
| `mcp_server_instance_id` | string | → mcp_server_instances.id |
| `device_id` | string | → devices.id |
| `sandbox_id` | string | → sandboxes.id; NULL when the row is about the host device itself. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
