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
| `category_id` | string | → mcp_categories.id; NULL until a category is assigned. |
| `source_type` | string | Publisher/provenance as text ('official' / 'community' / 'reference' / 'archived' / 'openai' / 'anthropic' / 'unknown'); never NULL, 'unknown' = unset. |
| `execution_environment` | string | JSON array of where the product runs, same vocabulary as mcp_server_instances.deployment_model ('local_process' / 'local_container' / 'local_service' / 'remote' / 'unknown'); '[]' when unset. |
| `authentication_methods` | string | JSON array of the auth methods the product supports, same vocabulary as mcp_server_instances.auth_type ('oauth' / 'token' / 'basic_auth' / 'no_auth' / 'unknown'); '[]' when unset. |
| `detection_patterns` | string | JSON text; how TraceForce recognizes it in configs. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
