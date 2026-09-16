# mcp_servers

Org-level rollup per MCP product: counts, scores, status. One row per product per org.

Joins:
- mcp_catalog_id → mcp_catalog.id only (FK; never org_mcp_catalog.id). For private/org products resolve by mcp_server_type against both catalogs and coalesce the names
- mcp_server_instances.mcp_server_id = mcp_servers.id
- The console's MCP list hides rollups with active_users = 0

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, mcp_server_type): one rollup per product per org

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `mcp_catalog_id` | string | → mcp_catalog.id (FK); NULL for products without a global catalog row |
| `mcp_server_type` | int | Product code; same as the catalogs' mcp_server_type. |
| `active_users` | int | Users seen using it. |
| `total_incidents` | int | Incidents raised. |
| `active_issues` | int | Open issues. |
| `affected_devices` | int | Devices with an instance. |
| `base_score` | double | Baseline risk score 0-100 for the product. |
| `actual_score` | double | Risk score 0-100 from your org's usage. |
| `agent_names` | string | JSON text; agents using it. |
| `distribution_channels` | string | JSON text. |
| `auth_types` | string | JSON text. |
| `sandbox_runtime_types` | string | JSON text. |
| `instance_count` | int | Number of instances. |
| `has_host_instances` | boolean | Any instance on a host (not only sandboxes). |
| `first_seen_at` | timestamp | First observed (UTC). |
| `last_reviewed` | timestamp | Last reviewed (UTC). |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
| `deleted_at` | timestamp | Soft delete. NULL = live. Filter `deleted_at IS NULL` for the current inventory. |
