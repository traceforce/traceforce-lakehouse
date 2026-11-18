-- Snowflake SQL version of ../models.sql: one row per (UTC day, agent, model).
-- GROUP BY by position: "agent" and "model" are also source columns, and Snowflake resolves a GROUP BY name
-- to the source column before an output alias (it would group by the raw values and split rows).
SELECT
  TO_CHAR("ts"::DATE, 'YYYY-MM-DD') AS "day",
  LOWER(REPLACE("agent", 'AGENT_IDENTITY_', '')) AS "agent",
  COALESCE("model", 'unknown') AS "model",
  COUNT(*) AS "requests",
  SUM("input_tokens") AS "input_tokens",
  SUM("output_tokens") AS "output_tokens",
  SUM("cache_read_tokens") AS "cache_read_tokens",
  SUM("cost_usd") AS "cost_usd"
FROM "agent_events"
WHERE "ts" >= DATEADD('day', -90, CURRENT_DATE())::TIMESTAMP_NTZ
  AND "operation" IS DISTINCT FROM 'invoke_agent'
  AND ("input_tokens" IS NOT NULL OR "cost_usd" IS NOT NULL)
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3
