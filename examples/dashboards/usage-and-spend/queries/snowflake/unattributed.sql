-- Snowflake SQL version of ../unattributed.sql: activity with no person, per (UTC day, agent, device serial).
WITH e AS (
  SELECT ev."ts"::DATE AS "day", LOWER(REPLACE(ev."agent", 'AGENT_IDENTITY_', '')) AS "agent",
         COALESCE(ev."device_native_id", 'unknown') AS "device_native_id",
         ev."ts" AS "ts", ev."session_id" AS "session_id", ev."tool_call_id" AS "tool_call_id", ev."signal" AS "signal",
         ev."operation" AS "operation", ev."input_tokens" AS "input_tokens", ev."output_tokens" AS "output_tokens",
         ev."cost_usd" AS "cost_usd"
  FROM "agent_events" ev
  LEFT JOIN "device_owner_mappings" m ON m."device_native_id" = ev."device_native_id"
  WHERE ev."ts" >= DATEADD('day', -90, CURRENT_DATE())::TIMESTAMP_NTZ
    AND ev."user_email" IS NULL AND m."owner_email" IS NULL
),
usage AS (
  SELECT "day", "agent", "device_native_id",
         COUNT(DISTINCT CASE WHEN "operation" = 'execute_tool' THEN "tool_call_id" END)
           + COUNT_IF("operation" = 'execute_tool' AND "tool_call_id" IS NULL AND "signal" = 'span') AS "tool_calls",
         SUM(CASE WHEN "operation" IS DISTINCT FROM 'invoke_agent' THEN COALESCE("input_tokens", 0) + COALESCE("output_tokens", 0) END) AS "tokens",
         SUM("cost_usd") AS "cost_usd"
  FROM e GROUP BY 1, 2, 3
),
sessions AS (
  SELECT "day", "agent", "device_native_id", COUNT(*) AS "sessions"
  FROM (SELECT MIN("ts")::DATE AS "day", "agent", "device_native_id", "session_id"
        FROM e WHERE "session_id" IS NOT NULL GROUP BY 2, 3, 4)
  GROUP BY 1, 2, 3
)
SELECT TO_CHAR(COALESCE(u."day", s."day"), 'YYYY-MM-DD') AS "day", COALESCE(u."agent", s."agent") AS "agent",
       COALESCE(u."device_native_id", s."device_native_id") AS "device_native_id",
       COALESCE(s."sessions", 0) AS "sessions", COALESCE(u."tool_calls", 0) AS "tool_calls",
       u."tokens" AS "tokens", u."cost_usd" AS "cost_usd"
FROM usage u
FULL OUTER JOIN sessions s ON s."day" = u."day" AND s."agent" = u."agent" AND s."device_native_id" = u."device_native_id"
ORDER BY 1, 2, 3
