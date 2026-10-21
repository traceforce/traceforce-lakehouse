# device_component_versions

Versions of TraceForce's own components on each device (scout, updater, proxy, browser extensions): one row per component, and per browser profile for extensions.

Joins:
- device_id → devices.id
- No deleted_at: rows for a removed component or browser profile stay, so judge freshness by updated_at

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, device_id, component, instance_id), NULLs compared as equal

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `device_id` | string | → devices.id |
| `component` | string | 'scout' / 'updater' / 'proxy' / 'chrome-extension' / 'edge-extension' / 'safari-extension'. |
| `instance_id` | string | The extension's per-browser-profile id; NULL for scout, updater and proxy. |
| `version` | string | Reported version: dotted numbers, though scout and updater can report a commit hash or 'unknown'. Compare part by part as numbers, never as text ('1.0.9' sorts above '1.0.52'). |
| `request_id` | string | Id of the check-in that last reported it. |
| `metadata` | string | JSON text; on scout's row, proxy status {proxy: {certInstalled, pacURL}}; NULL otherwise. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Last check-in that reported this component (UTC). |
