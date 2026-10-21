# user_group_devices

Devices in manual user groups.

Joins:
- user_group_id → user_groups.id
- device_id → devices.id
- No deleted_at: a device removed from a group leaves this table

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, device_id, user_group_id)

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `user_group_id` | string | → user_groups.id |
| `device_id` | string | → devices.id |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
