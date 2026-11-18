-- Snowflake SQL version of ../sessions.sql: one person's sessions in the last 90 days.
-- MIN(device_native_id) where Databricks has any_value(..., true): Snowflake's ANY_VALUE may pick a NULL.
WITH e AS (
  SELECT
    LOWER(REPLACE(ev."agent", 'AGENT_IDENTITY_', '')) AS "agent",
    COALESCE(LOWER(ev."user_email"), LOWER(m."owner_email")) AS "person",
    ev."session_id" AS "session_id", ev."device_native_id" AS "device_native_id", ev."ts" AS "ts",
    CASE WHEN (ev."input_tokens" IS NOT NULL OR ev."cost_usd" IS NOT NULL) AND ev."operation" IS DISTINCT FROM 'invoke_agent'
      THEN ev."model" END AS "priced_model",
    ev."prompt_id" AS "prompt_id", ev."generation_id" AS "generation_id", ev."tool_call_id" AS "tool_call_id",
    ev."signal" AS "signal", ev."operation" AS "operation", ev."input_tokens" AS "input_tokens",
    ev."output_tokens" AS "output_tokens", ev."cost_usd" AS "cost_usd"
  FROM "agent_events" ev
  LEFT JOIN "device_owner_mappings" m ON m."device_native_id" = ev."device_native_id"
  WHERE ev."ts" >= DATEADD('day', -91, CURRENT_DATE())::TIMESTAMP_NTZ
    AND ev."session_id" IS NOT NULL
    AND COALESCE(LOWER(ev."user_email"), LOWER(m."owner_email")) IS NOT DISTINCT FROM {{person}}
)
SELECT
  "agent", "person", "session_id",
  MIN("device_native_id") AS "device_native_id",
  TO_CHAR(MIN("ts"), 'YYYY-MM-DD HH24:MI:SS.FF6') AS "started_at",
  TO_CHAR(MAX("ts"), 'YYYY-MM-DD HH24:MI:SS.FF6') AS "ended_at",
  LISTAGG(DISTINCT "priced_model", ', ') WITHIN GROUP (ORDER BY "priced_model") AS "models",
  COUNT(DISTINCT COALESCE("prompt_id", "generation_id")) AS "prompts",
  COUNT(DISTINCT CASE WHEN "operation" = 'execute_tool' THEN "tool_call_id" END)
    + COUNT_IF("operation" = 'execute_tool' AND "tool_call_id" IS NULL AND "signal" = 'span') AS "tool_calls",
  SUM(CASE WHEN "operation" IS DISTINCT FROM 'invoke_agent' THEN "input_tokens" END) AS "input_tokens",
  SUM(CASE WHEN "operation" IS DISTINCT FROM 'invoke_agent' THEN "output_tokens" END) AS "output_tokens",
  SUM("cost_usd") AS "cost_usd"
FROM e
GROUP BY 1, 2, 3
HAVING MIN("ts") >= DATEADD('day', -90, CURRENT_DATE())::TIMESTAMP_NTZ
ORDER BY "started_at"
