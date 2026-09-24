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
| `category_id` | string | → mcp_categories.id; NULL until a category is assigned. |
| `source_type` | string | Publisher/provenance as text ('official' / 'community' / 'reference' / 'archived' / 'openai' / 'anthropic' / 'unknown'); never NULL, 'unknown' = unset. |
| `execution_environment` | string | JSON array of where the product runs, same vocabulary as mcp_server_instances.deployment_model ('local_process' / 'local_container' / 'local_service' / 'remote' / 'unknown'); `[]` when unset. |
| `authentication_methods` | string | JSON array of the auth methods the product supports, same vocabulary as mcp_server_instances.auth_type ('oauth' / 'token' / 'basic_auth' / 'no_auth' / 'unknown'); `[]` when unset. |
| `detection_patterns` | string | JSON text. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
