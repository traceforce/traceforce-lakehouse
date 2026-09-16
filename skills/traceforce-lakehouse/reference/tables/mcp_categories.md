# mcp_categories

Global reference: MCP product categories (Databases & Data Storage, OS and Local File Systems, Security Tools, ...).

Joins:
- mcp_categories.id = mcp_catalog.category_id

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- id only

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `name` | string | Category name. |
| `description` | string | Category description. |
| `resource_type` | string | Sensitivity class of what servers in this category reach. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
