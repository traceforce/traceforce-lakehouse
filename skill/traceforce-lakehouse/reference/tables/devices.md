# devices

One row per device TraceForce has seen (laptops, workstations). The anchor for every join from the logs.

Joins:
- agent_events.device_uuid = devices.device_uuid when the event has one (Windows), else agent_events.device_native_id = devices.device_native_id

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, coalesce(device_uuid, device_native_id)): one row per device; a Windows device keyed by GUID may share its serial with others

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `device_native_id` | string | OS-reported serial (e.g. C02XXXXXXXXX on macOS). Same value as agent_events.device_native_id. Windows serials can be placeholders shared by many machines. |
| `device_uuid` | string | Windows per-install GUID; NULL on macOS/Linux. Prefer it over the serial when present. agent_events.device_uuid is NULL on every row until the collector release that stamps it ships, so today the device join degenerates to the serial. |
| `friendly_name` | string | Human-readable name (e.g. Jane's MacBook Pro). |
| `platform` | string | darwin / windows / linux. |
| `architecture` | string | CPU architecture (arm64, x86_64). |
| `os_version` | string | OS version string. |
| `chip_model` | string | Chip model when reported. |
| `account_metadata` | string | JSON text keyed by OS uid/SID with the OS username; how agent_instances.tenant resolves to a username. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
| `last_seen_at` | timestamp | Most recent check-in that observed this row (UTC). |
| `deleted_at` | timestamp | Soft delete. NULL = live. Filter `deleted_at IS NULL` for the current inventory. |
