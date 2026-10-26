-- BigQuery (GoogleSQL) version of ../unattributed_devices.sql: what TraceForce knows about each unattributed serial.
-- Also in traceforce-ui src/lib/lakehouse/queries/usage.ts (the in-app GCP dashboards): keep the two in sync.
WITH serials AS (
  SELECT DISTINCT ev.device_native_id
  FROM traceforce_lakehouse.agent_events ev
  LEFT JOIN traceforce_lakehouse.device_owner_mappings m ON m.device_native_id = ev.device_native_id
  WHERE ev.ts >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY))
    AND ev.user_email IS NULL AND m.owner_email IS NULL AND ev.device_native_id IS NOT NULL
)
SELECT
  s.device_native_id,
  count(DISTINCT d.id) AS live_devices,
  STRING_AGG(DISTINCT d.friendly_name, ', ' ORDER BY d.friendly_name) AS device_names,
  STRING_AGG(DISTINCT d.platform, ', ' ORDER BY d.platform) AS platforms,
  FORMAT_TIMESTAMP('%F %H:%M:%E6S', max(d.last_seen_at)) AS last_seen_at,
  CASE WHEN LOGICAL_OR(m.device_native_id IS NOT NULL) THEN 'MDM record, no owner' ELSE 'No MDM record' END AS mdm_status,
  STRING_AGG(DISTINCT lower(a.agent_email), ', ' ORDER BY lower(a.agent_email)) AS accounts
FROM serials s
LEFT JOIN traceforce_lakehouse.devices d ON d.device_native_id = s.device_native_id AND d.deleted_at IS NULL
LEFT JOIN traceforce_lakehouse.device_owner_mappings m ON m.device_native_id = s.device_native_id
LEFT JOIN traceforce_lakehouse.agent_accounts a ON a.device_id = d.id AND a.deleted_at IS NULL AND a.agent_email IS NOT NULL AND a.agent_email <> ''
GROUP BY s.device_native_id
ORDER BY 1
