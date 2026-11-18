-- Snowflake SQL version of ../findings.sql: every finding from the last 90 days, one row each.
-- MIN where Athena has arbitrary(): Snowflake's ANY_VALUE may pick a NULL. at has six fraction digits always:
-- api.mjs sorts findings by at as a string. The script runs the session in UTC, so CURRENT_DATE() is the UTC date.
WITH f AS (
  SELECT "id" AS "id", 'sensitive_data' AS "kind", "conversation_id" AS "conversation_id", "device_id" AS "device_id",
         "message_timestamp" AS "at", "finding_status" AS "status", "category" AS "category", "type" AS "type",
         CAST(NULL AS VARCHAR) AS "outcome",
         -- Where the match is; the matched value itself is never in the lake.
         CASE WHEN "file_id" IS NOT NULL THEN 'in an attached file' ELSE 'in a message' END
           || CASE WHEN "encoding_type" IS NOT NULL THEN ' (' || "encoding_type" || ' encoded)' ELSE '' END AS "detail",
         "message_external_id" AS "message_external_id", CAST(NULL AS VARCHAR) AS "tool_use_id", "issue_detail" AS "issue_detail"
  FROM "sensitive_data_findings"
  WHERE "message_timestamp" >= DATEADD('day', -90, CURRENT_DATE())::TIMESTAMP_NTZ
  UNION ALL
  SELECT "id" AS "id", 'risky_action' AS "kind", "conversation_id" AS "conversation_id", "device_id" AS "device_id",
         "detected_at" AS "at", "finding_status" AS "status", "risky_action_category" AS "category",
         "risky_action_subcategory" AS "type", "outcome" AS "outcome",
         "op" || ' via ' || "tool_name" || CASE WHEN "operation" <> '' THEN ': ' || "operation" ELSE '' END AS "detail",
         CAST(NULL AS VARCHAR) AS "message_external_id", "tool_use_id" AS "tool_use_id", "issue_detail" AS "issue_detail"
  FROM "connector_containment_findings"
  WHERE "detected_at" >= DATEADD('day', -90, CURRENT_DATE())::TIMESTAMP_NTZ
  UNION ALL
  SELECT "id" AS "id", 'prompt_injection' AS "kind", "conversation_id" AS "conversation_id", "device_id" AS "device_id",
         "detected_at" AS "at", "finding_status" AS "status", 'prompt_injection' AS "category", 'prompt_injection' AS "type",
         CAST(NULL AS VARCHAR) AS "outcome", "description" AS "detail", "message_external_id" AS "message_external_id",
         CAST(NULL AS VARCHAR) AS "tool_use_id", "issue_detail" AS "issue_detail"
  FROM "prompt_injection_findings"
  WHERE "detected_at" >= DATEADD('day', -90, CURRENT_DATE())::TIMESTAMP_NTZ
),
ev AS (
  SELECT "session_id" AS "session_id", MIN(LOWER(REPLACE("agent", 'AGENT_IDENTITY_', ''))) AS "agent"
  FROM "agent_events"
  WHERE "ts" >= DATEADD('day', -91, CURRENT_DATE())::TIMESTAMP_NTZ AND "session_id" IS NOT NULL
  GROUP BY 1
)
SELECT
  f."id", f."kind", TO_CHAR(f."at", 'YYYY-MM-DD HH24:MI:SS.FF6') AS "at", TO_CHAR(f."at"::DATE, 'YYYY-MM-DD') AS "day",
  f."status", f."category", f."type", sdt."name" AS "type_name", f."outcome", SUBSTR(f."detail", 1, 600) AS "detail", f."message_external_id",
  f."tool_use_id", it."criticality",
  LOWER(a."agent_email") AS "person",
  COALESCE(CASE WHEN REGEXP_LIKE(a."agent_type", '^[0-9]*$') THEN NULL ELSE LOWER(a."agent_type") END,
           REGEXP_REPLACE(LOWER(ct."agent_name"), '[^a-z0-9]+', '_'), ev."agent") AS "agent",
  c."conversation_external_id" AS "session_id", c."name" AS "session_name",
  COALESCE(d."friendly_name", d."device_native_id") AS "device"
FROM f
JOIN "agent_conversations" c ON c."id" = f."conversation_id"
JOIN "agent_accounts" a ON a."id" = c."agent_account_id"
LEFT JOIN "agent_catalog" ct ON ct."agent_type" = a."agent_type"
LEFT JOIN ev ON ev."session_id" = c."conversation_external_id"
LEFT JOIN "devices" d ON d."id" = f."device_id"
LEFT JOIN "issue_types" it ON it."issue_detail" = f."issue_detail" AND it."applicable_to" = 'instance'
LEFT JOIN "org_sensitive_data_custom_types" sdt ON sdt."type" = f."type"
ORDER BY f."at"
