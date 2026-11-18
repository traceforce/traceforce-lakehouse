-- Snowflake SQL version of ../unattributed_devices.sql: what TraceForce knows about each unattributed serial.
-- LISTAGG(DISTINCT ...) of only NULLs is '', which the page reads as empty, as on the other engines.
WITH serials AS (
  SELECT DISTINCT ev."device_native_id" AS "device_native_id"
  FROM "agent_events" ev
  LEFT JOIN "device_owner_mappings" m ON m."device_native_id" = ev."device_native_id"
  WHERE ev."ts" >= DATEADD('day', -90, CURRENT_DATE())::TIMESTAMP_NTZ
    AND ev."user_email" IS NULL AND m."owner_email" IS NULL AND ev."device_native_id" IS NOT NULL
)
SELECT
  s."device_native_id" AS "device_native_id",
  COUNT(DISTINCT d."id") AS "live_devices",
  LISTAGG(DISTINCT d."friendly_name", ', ') WITHIN GROUP (ORDER BY d."friendly_name") AS "device_names",
  LISTAGG(DISTINCT d."platform", ', ') WITHIN GROUP (ORDER BY d."platform") AS "platforms",
  TO_CHAR(MAX(d."last_seen_at"), 'YYYY-MM-DD HH24:MI:SS.FF6') AS "last_seen_at",
  CASE WHEN BOOLOR_AGG(m."device_native_id" IS NOT NULL) THEN 'MDM record, no owner' ELSE 'No MDM record' END AS "mdm_status",
  LISTAGG(DISTINCT LOWER(a."agent_email"), ', ') WITHIN GROUP (ORDER BY LOWER(a."agent_email")) AS "accounts"
FROM serials s
LEFT JOIN "devices" d ON d."device_native_id" = s."device_native_id" AND d."deleted_at" IS NULL
LEFT JOIN "device_owner_mappings" m ON m."device_native_id" = s."device_native_id"
LEFT JOIN "agent_accounts" a
  ON a."device_id" = d."id" AND a."deleted_at" IS NULL AND a."agent_email" IS NOT NULL AND a."agent_email" <> ''
GROUP BY s."device_native_id"
ORDER BY 1
