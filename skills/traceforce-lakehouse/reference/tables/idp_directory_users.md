# idp_directory_users

People in your identity provider's directory, as synced to TraceForce.

Joins:
- idp_directory_users.id = user_group_members.idp_directory_user_id
- Their devices: lower(device_owner_mappings.owner_email) = idp_directory_users.email
- IdP: idp_integration_id = user_groups.idp_integration_id, then user_groups.user_group_source

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (idp_integration_id, external_user_id): the same person appears once per directory; email is not unique

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `idp_integration_id` | string | The directory the person was synced from (that table is not in the lake). |
| `external_user_id` | string | The directory sync's user id; changes when the directory is reconnected. |
| `external_idp_id` | string | The IdP's own user id; survives a reconnect. NULL when the IdP gives none. |
| `email` | string | Email, lowercase. The same person can have one row per directory. |
| `first_name` | string | First name. |
| `last_name` | string | Last name. |
| `display_name` | string | Display name. |
| `state` | string | Directory state as text ('active' / 'suspended' / 'inactive' / 'unknown'). |
| `external_updated_at` | timestamp | The IdP's last update of the person (UTC). |
| `last_seen_at` | timestamp | Last directory sync that saw the person (UTC). |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
| `deleted_at` | timestamp | Soft delete. NULL = live. Filter `deleted_at IS NULL` for the current inventory. |
