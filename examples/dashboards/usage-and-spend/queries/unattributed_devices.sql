-- What TraceForce knows about each serial behind unattributed activity: device name, MDM status, and the
-- agent accounts signed in on it (a hint for who the owner is, never proof; see reference/identity.md).
-- A Windows serial can be a placeholder shared by several machines: live_devices > 1 flags that.
WITH serials AS (
  SELECT DISTINCT ev.device_native_id
  FROM agent_events ev
  LEFT JOIN device_owner_mappings m ON m.device_native_id = ev.device_native_id
  WHERE ev.ts >= date_add('day', -90, current_date)
    AND ev.user_email IS NULL AND m.owner_email IS NULL AND ev.device_native_id IS NOT NULL
)
SELECT
  s.device_native_id,
  count(DISTINCT d.id) AS live_devices,
  array_join(array_sort(array_distinct(array_agg(d.friendly_name))), ', ') AS device_names,
  array_join(array_sort(array_distinct(array_agg(d.platform))), ', ') AS platforms,
  cast(max(d.last_seen_at) AS varchar) AS last_seen_at,
  CASE WHEN bool_or(m.device_native_id IS NOT NULL) THEN 'MDM record, no owner' ELSE 'No MDM record' END AS mdm_status,
  array_join(array_sort(array_distinct(array_agg(lower(a.agent_email)))), ', ') AS accounts
FROM serials s
LEFT JOIN devices d ON d.device_native_id = s.device_native_id AND d.deleted_at IS NULL
LEFT JOIN device_owner_mappings m ON m.device_native_id = s.device_native_id
LEFT JOIN agent_accounts a ON a.device_id = d.id AND a.deleted_at IS NULL AND a.agent_email IS NOT NULL AND a.agent_email <> ''
GROUP BY s.device_native_id
ORDER BY 1
