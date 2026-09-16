# agent_catalog

Global reference: agent_type → product name, one row per known agent type.

Joins:
- agent_catalog.agent_type = agent_instances.agent_type (or agent_accounts / agent_events.agent_type)

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- agent_type
- agent_name
- website

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `agent_name` | string | Display name (Claude Code, Cursor, GitHub Copilot, ChatGPT, ...). |
| `description` | string | Catalog description. |
| `website` | string | Vendor website. |
| `logo_url` | string | Logo URL. |
| `agent_type` | int | The integer code used everywhere else; join key, not decoded. |
| `domain` | string | Vendor domain. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
