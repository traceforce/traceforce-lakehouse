# user_groups

User groups: manual groups of devices, and groups synced from your identity provider (IdP).

Joins:
- Manual groups (user_group_source = 'manual') list devices in user_group_devices; IdP groups list people in user_group_members. Group to devices: reference/joins.md
- idp_integration_id = idp_directory_users.idp_integration_id (people of the same directory)

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, idp_integration_id, external_id) for synced groups

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `name` | string | Group name. |
| `user_group_source` | string | Where the group comes from, as text: 'manual', or the IdP ('okta' / 'entra' / 'onelogin' / 'gsuite' / 'cyberark' / 'jumpcloud' / 'pingfederate' / 'rippling' / 'sailpoint'). |
| `idp_integration_id` | string | The IdP directory a synced group comes from (that table is not in the lake); NULL for manual groups. |
| `external_id` | string | The directory sync's group id; changes when the directory is reconnected. NULL for manual groups. |
| `external_idp_id` | string | The IdP's own group id; survives a reconnect (for some IdPs it is the group name). NULL for manual groups. |
| `last_modified_at` | timestamp | When the group was created or last renamed in the console (UTC). |
| `external_updated_at` | timestamp | The IdP's last update of the group (UTC). |
| `last_seen_at` | timestamp | Last directory sync that saw the group (UTC). |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
| `deleted_at` | timestamp | Soft delete. NULL = live. Filter `deleted_at IS NULL` for the current inventory. |
