# user_group_members

Members (people, by email) of groups synced from your identity provider.

Joins:
- user_group_id → user_groups.id
- idp_directory_user_id → idp_directory_users.id
- A member reaches devices through the MDM owner: member_email = lower(device_owner_mappings.owner_email); see reference/joins.md

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, user_group_id, member_email), including removed (deleted_at set) rows

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `user_group_id` | string | → user_groups.id |
| `member_email` | string | Member's email, lowercase. |
| `external_user_id` | string | The directory sync's user id. |
| `idp_directory_user_id` | string | → idp_directory_users.id; NULL when the member has no directory user row. |
| `state` | string | The person's directory state as text ('active' / 'suspended' / 'inactive' / 'unknown'), copied from idp_directory_users.state. Only 'active' members resolve to devices. |
| `external_updated_at` | timestamp | The IdP's last update (UTC). |
| `last_seen_at` | timestamp | Last directory sync that saw the membership (UTC). |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
| `deleted_at` | timestamp | Soft delete. NULL = live. Filter `deleted_at IS NULL` for the current inventory. |
