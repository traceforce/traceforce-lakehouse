# org_mcp_catalog

Same shape as mcp_catalog, for private/custom MCP servers specific to your org.

Joins:
- org_mcp_catalog.mcp_server_type = mcp_server_instances.mcp_server_type
- category_id → mcp_categories.id

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, mcp_server_type)
- (org_id, mcp_server_name)

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `mcp_server_name` | string | Product display name. |
| `description` | string | Catalog description. |
| `website` | string | Vendor website. |
| `logo_url` | string | Logo URL. |
| `mcp_server_type` | int | Product code. |
| `category_id` | string | → mcp_categories.id |
| `source_type` | string | Who publishes it. |
| `execution_environment` | string | JSON text. |
| `authentication_methods` | string | JSON text. |
| `detection_patterns` | string | JSON text. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
