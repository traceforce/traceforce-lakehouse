-- Databricks SQL version of ../unattributed_devices.sql: what TraceForce knows about each unattributed serial.
WITH serials AS (
  SELECT DISTINCT ev.device_native_id
  FROM traceforce_lakehouse.traceforce.agent_events ev
  LEFT JOIN traceforce_lakehouse.traceforce.device_owner_mappings m ON m.device_native_id = ev.device_native_id
  WHERE ev.ts >= CAST(date_sub(to_date(timestampadd(MICROSECOND, unix_micros(current_timestamp()), TIMESTAMP_NTZ '1970-01-01 00:00:00')), 90) AS TIMESTAMP_NTZ)
    AND ev.user_email IS NULL AND m.owner_email IS NULL AND ev.device_native_id IS NOT NULL
)
SELECT
  s.device_native_id,
  count(DISTINCT d.id) AS live_devices,
  array_join(array_sort(array_distinct(collect_list(d.friendly_name))), ', ') AS device_names,
  array_join(array_sort(array_distinct(collect_list(d.platform))), ', ') AS platforms,
  CAST(max(d.last_seen_at) AS STRING) AS last_seen_at,
  CASE WHEN bool_or(m.device_native_id IS NOT NULL) THEN 'MDM record, no owner' ELSE 'No MDM record' END AS mdm_status,
  array_join(array_sort(array_distinct(collect_list(lower(a.agent_email)))), ', ') AS accounts
FROM serials s
LEFT JOIN traceforce_lakehouse.traceforce.devices d ON d.device_native_id = s.device_native_id AND d.deleted_at IS NULL
LEFT JOIN traceforce_lakehouse.traceforce.device_owner_mappings m ON m.device_native_id = s.device_native_id
LEFT JOIN traceforce_lakehouse.traceforce.agent_accounts a
  ON a.device_id = d.id AND a.deleted_at IS NULL AND a.agent_email IS NOT NULL AND a.agent_email <> ''
GROUP BY s.device_native_id
ORDER BY 1
