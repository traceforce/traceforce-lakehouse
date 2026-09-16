# mcp_catalog

Global reference: MCP products TraceForce knows.

Joins:
- mcp_catalog.mcp_server_type = mcp_server_instances.mcp_server_type
- category_id → mcp_categories.id

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- mcp_server_type
- mcp_server_name

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `mcp_server_name` | string | Product display name (Slack, Notion, Supabase, ...). |
| `description` | string | Catalog description. |
| `website` | string | Vendor website. |
| `logo_url` | string | Logo URL. |
| `mcp_server_type` | int | Product code used by instances and rollups. |
| `category_id` | string | → mcp_categories.id |
| `source_type` | string | Who publishes it. |
| `execution_environment` | string | JSON text. |
| `authentication_methods` | string | JSON text. |
| `detection_patterns` | string | JSON text; how TraceForce recognizes it in configs. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
