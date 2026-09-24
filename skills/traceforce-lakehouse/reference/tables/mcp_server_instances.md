# mcp_server_instances

MCP servers configured on a device for an agent. The MCP inventory; the name matches what the logs carry.

Joins:
- lower(mcp_server_instances.mcp_native_id) = lower(agent_events.mcp_server_name) AND mcp_server_instances.agent_type = agent_events.agent_type, on the same device via mcp_server_instances.device_id → devices.device_native_id = agent_events.device_native_id (events carry no device_id). Not a key: the same server name can have several live rows per device (one per project_path or location), so aggregate or SELECT DISTINCT
- account: agent_account_id when set; else mcp_server_agent_instances → agent_instances_accounts → agent_accounts, taking the greatest agent_accounts.last_seen_at when several match (the console's rule)
- mcp_server_id → mcp_servers.id
- mcp_server_type → mcp_catalog.mcp_server_type or org_mcp_catalog.mcp_server_type (product name)
- mcp_server_agent_instances links to the install it is configured in

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, device_id, sandbox_id, agent_account_id, mcp_server_location, mcp_native_id, project_path): the same server name can appear once per project path

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `device_id` | string | → devices.id |
| `sandbox_id` | string | → sandboxes.id; NULL when the row is about the host device itself. |
| `agent_account_id` | string | → agent_accounts.id: the account a browser-connector MCP belongs to. NULL for filesystem-discovered MCPs — attribute those via mcp_server_agent_instances → agent_instances_accounts → agent_accounts (take the greatest agent_accounts.last_seen_at when several match). |
| `mcp_server_id` | string | → mcp_servers.id (org rollup). |
| `mcp_server_type` | int | Integer product code; join the catalogs for the name. Not an enum. |
| `mcp_server_location` | string | URL for remote servers, command/path for local ones. |
| `mcp_native_id` | string | The server's key in the host config (mcp.json). Equals agent_events.mcp_server_name (case-insensitive). |
| `transport_type` | string | Transport protocol as text ('stdio' / 'http' / 'sse' / 'unknown'); never NULL, 'unknown' = unclassified. |
| `deployment_model` | string | Where the server runs, as text ('local_process' / 'local_container' / 'local_service' / 'remote' / 'unknown'); never NULL, 'unknown' = unclassified. |
| `auth_type` | string | Authentication method as text ('oauth' / 'token' / 'basic_auth' / 'no_auth' / 'unknown'); never NULL, 'unknown' = no method detected. |
| `transport_security_type` | string | Transport encryption as text ('none' / 'tls' / 'unknown'); never NULL, 'unknown' = unclassified. |
| `distribution_channel` | string | Who provisioned it, as text ('platform' / 'tenant' / 'user' / 'unknown'); never NULL, filesystem MCPs are 'user', 'unknown' = unmatched. |
| `agent_type` | int | Agent it is configured for. |
| `project_path` | string | Project/workspace path the MCP is scoped to; NULL for global-scope configs and browser connectors. |
| `linked_plans` | string | JSON array of AgentPlanType text the instance is reachable through — its direct account plus junction-linked installs (e.g. ["personal","enterprise"]). NULL or `[]` when it has neither a direct account nor an active junction link. Attribute an instance to agents as agent_type x each element: CROSS JOIN UNNEST(CAST(json_parse(linked_plans) AS array(varchar))) AS t(plan). |
| `metadata` | string | JSON text. On the findings tables: reviewer close tracking {statusComment, statusUpdatedAt, statusUpdatedBy}, empty or NULL until a reviewer closes the finding; elsewhere vendor-specific extras (e.g. version). |
| `security_findings` | string | JSON text; TraceForce's security observations for this instance. |
| `tools` | string | JSON text; tools the server exposes, as discovered on this install. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
| `last_seen_at` | timestamp | Most recent check-in that observed this row (UTC). |
| `deleted_at` | timestamp | Soft delete. NULL = live. Filter `deleted_at IS NULL` for the current inventory. |
