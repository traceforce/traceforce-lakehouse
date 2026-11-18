-- Snowflake SQL version of ../activity.sql: one row per (UTC day, agent, person).
-- The script runs the session in UTC, so CURRENT_DATE() is the UTC date. Derived columns are computed in
-- the e CTE and grouped by position: Snowflake resolves a GROUP BY name to a source column first.
WITH e AS (
  SELECT
    ev."ts"::DATE AS "day",
    LOWER(REPLACE(ev."agent", 'AGENT_IDENTITY_', '')) AS "agent",
    COALESCE(LOWER(ev."user_email"), LOWER(m."owner_email")) AS "person",
    ev."ts" AS "ts", ev."session_id" AS "session_id", ev."prompt_id" AS "prompt_id",
    ev."generation_id" AS "generation_id", ev."tool_call_id" AS "tool_call_id", ev."signal" AS "signal",
    ev."operation" AS "operation", ev."input_tokens" AS "input_tokens", ev."output_tokens" AS "output_tokens",
    ev."cache_read_tokens" AS "cache_read_tokens", ev."cost_usd" AS "cost_usd"
  FROM "agent_events" ev
  LEFT JOIN "device_owner_mappings" m ON m."device_native_id" = ev."device_native_id"
  WHERE ev."ts" >= DATEADD('day', -90, CURRENT_DATE())::TIMESTAMP_NTZ
),
usage AS (
  SELECT
    "day", "agent", "person",
    COUNT(DISTINCT COALESCE("prompt_id", "generation_id")) AS "prompts",
    COUNT(DISTINCT CASE WHEN "operation" = 'execute_tool' THEN "tool_call_id" END)
      + COUNT_IF("operation" = 'execute_tool' AND "tool_call_id" IS NULL AND "signal" = 'span') AS "tool_calls",
    SUM(CASE WHEN "operation" IS DISTINCT FROM 'invoke_agent' THEN "input_tokens" END) AS "input_tokens",
    SUM(CASE WHEN "operation" IS DISTINCT FROM 'invoke_agent' THEN "output_tokens" END) AS "output_tokens",
    SUM(CASE WHEN "operation" IS DISTINCT FROM 'invoke_agent' THEN "cache_read_tokens" END) AS "cache_read_tokens",
    SUM("cost_usd") AS "cost_usd"
  FROM e
  GROUP BY 1, 2, 3
),
sessions AS (
  SELECT "day", "agent", "person", COUNT(*) AS "sessions"
  FROM (
    SELECT MIN("ts")::DATE AS "day", "agent", "person", "session_id"
    FROM e WHERE "session_id" IS NOT NULL
    GROUP BY 2, 3, 4
  )
  GROUP BY 1, 2, 3
)
SELECT
  TO_CHAR(COALESCE(u."day", s."day"), 'YYYY-MM-DD') AS "day",
  COALESCE(u."agent", s."agent") AS "agent",
  COALESCE(u."person", s."person") AS "person",
  COALESCE(s."sessions", 0) AS "sessions",
  COALESCE(u."prompts", 0) AS "prompts",
  COALESCE(u."tool_calls", 0) AS "tool_calls",
  u."input_tokens" AS "input_tokens", u."output_tokens" AS "output_tokens",
  u."cache_read_tokens" AS "cache_read_tokens", u."cost_usd" AS "cost_usd"
FROM usage u
FULL OUTER JOIN sessions s
  ON s."day" = u."day" AND s."agent" = u."agent" AND s."person" IS NOT DISTINCT FROM u."person"
ORDER BY 1, 2, 3
