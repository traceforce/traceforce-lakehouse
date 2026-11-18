-- Snowflake SQL version of ../tools.sql: one person's tool calls per (UTC day, agent, tool).
-- calls groups by name: tool_call_id isn't in its select list, and "agent" and "person" there are the e
-- CTE's columns, not derived aliases.
WITH e AS (
  SELECT
    ev."ts"::DATE AS "day",
    LOWER(REPLACE(ev."agent", 'AGENT_IDENTITY_', '')) AS "agent",
    COALESCE(LOWER(ev."user_email"), LOWER(m."owner_email")) AS "person",
    ev."tool_call_id" AS "tool_call_id", ev."tool_name" AS "tool_name", ev."mcp_server_name" AS "mcp_server_name",
    ev."signal" AS "signal"
  FROM "agent_events" ev
  LEFT JOIN "device_owner_mappings" m ON m."device_native_id" = ev."device_native_id"
  WHERE ev."ts" >= DATEADD('day', -90, CURRENT_DATE())::TIMESTAMP_NTZ
    AND ev."operation" = 'execute_tool'
    AND COALESCE(LOWER(ev."user_email"), LOWER(m."owner_email")) IS NOT DISTINCT FROM {{person}}
),
calls AS (
  SELECT MIN("day") AS "day", "agent", "person",
         COALESCE(MAX(CASE WHEN "tool_name" <> 'mcp_tool' THEN "tool_name" END), MAX("tool_name")) AS "tool_name",
         MAX("mcp_server_name") AS "mcp_server_name"
  FROM e WHERE "tool_call_id" IS NOT NULL
  GROUP BY "agent", "person", "tool_call_id"
  UNION ALL
  SELECT "day", "agent", "person", "tool_name", "mcp_server_name"
  FROM e WHERE "tool_call_id" IS NULL AND "signal" = 'span'
)
SELECT
  TO_CHAR("day", 'YYYY-MM-DD') AS "day", "agent", "person",
  CASE WHEN "mcp_server_name" IS NOT NULL THEN "mcp_server_name" || '/' || COALESCE("tool_name", '?')
       ELSE COALESCE("tool_name", 'unknown') END AS "tool",
  COUNT(*) AS "calls"
FROM calls
GROUP BY 1, 2, 3, 4
ORDER BY 1, 2, 3, 5 DESC
