# sandboxes

Devcontainers / cloud VMs an agent ran in.

Joins:
- sandboxes.parent_device_id = devices.id
- agent_events.sandbox_native_id = sandboxes.sandbox_native_id (reserved; NULL in events today)

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, parent_device_id, sandbox_native_id)

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `parent_device_id` | string | → devices.id of the host. |
| `sandbox_native_id` | string | Sandbox identifier; join key to agent_events.sandbox_native_id. |
| `runtime_type` | string | Sandbox runtime as text ('devcontainer' / 'unspecified'). |
| `workspace_folder` | string | Workspace path inside the sandbox. |
| `friendly_name` | string | Display name. |
| `os_version` | string | Guest OS version. |
| `account_metadata` | string | JSON text; OS users inside the sandbox. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
| `last_seen_at` | timestamp | Most recent check-in that observed this row (UTC). |
| `deleted_at` | timestamp | Soft delete. NULL = live. Filter `deleted_at IS NULL` for the current inventory. |
