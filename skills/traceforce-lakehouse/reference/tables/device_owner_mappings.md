# device_owner_mappings

Device owner from your MDM.

Joins:
- device_owner_mappings.device_native_id = agent_events.device_native_id (or = devices.device_native_id)

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, device_native_id): at most one owner per serial

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `mdm_integration_id` | string | Which MDM integration produced the mapping. |
| `device_native_id` | string | Serial as reported by the MDM. |
| `owner_email` | string | Owner/assigned-user email from your MDM; NULL for shared or bulk-enrolled devices with no assigned user. |
| `owner_name` | string | Owner display name from the MDM. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
