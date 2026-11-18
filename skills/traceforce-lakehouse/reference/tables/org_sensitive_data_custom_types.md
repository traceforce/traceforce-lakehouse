# org_sensitive_data_custom_types

Your org's custom sensitive-data types: one row per type an admin defined, with its name and category.

Joins:
- org_sensitive_data_custom_types.type = sensitive_data_findings.type (LEFT JOIN: built-in types have no row)

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, type)
- (org_id, lower(trim(name)))

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `type` | string | 'custom_<id>'; the same value sensitive_data_findings.type carries for a finding of this type. |
| `category` | string | Sensitive-data class as text, same vocabulary as sensitive_data_findings.category (e.g. 'credentials'). |
| `name` | string | Display name the admin gave the type. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
