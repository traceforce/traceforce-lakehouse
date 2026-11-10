-- Databricks SQL version of ../recent_sessions.sql: the 30 most recent sessions across everyone.
-- {{since}} is UTC: the runner must write it as TIMESTAMP_NTZ '...'. A TIMESTAMP '...' literal is read in the
-- session's time zone and moves an hour inside a daylight-saving gap.
WITH e AS (
  SELECT
    lower(replace(ev.agent, 'AGENT_IDENTITY_', '')) AS agent,
    coalesce(lower(ev.user_email), lower(m.owner_email)) AS person,
    ev.session_id, ev.device_native_id, ev.ts, ev.model, ev.prompt_id, ev.generation_id, ev.tool_call_id,
    ev.signal, ev.operation, ev.input_tokens, ev.output_tokens, ev.cost_usd
  FROM traceforce_lakehouse.traceforce.agent_events ev
  LEFT JOIN traceforce_lakehouse.traceforce.device_owner_mappings m ON m.device_native_id = ev.device_native_id
  WHERE ev.ts >= CAST({{since}} AS TIMESTAMP_NTZ) - INTERVAL 1 DAY AND ev.session_id IS NOT NULL
    AND ev.model IS DISTINCT FROM 'codex-auto-review' -- Codex's internal approval reviewer, not a user's session
    AND ({{agent}} IS NULL OR lower(replace(ev.agent, 'AGENT_IDENTITY_', '')) = {{agent}})
)
SELECT
  agent, person, session_id,
  any_value(device_native_id, true) AS device_native_id,
  CAST(min(ts) AS STRING) AS started_at,
  CAST(max(ts) AS STRING) AS ended_at,
  array_join(array_sort(array_distinct(collect_list(
    CASE WHEN (input_tokens IS NOT NULL OR cost_usd IS NOT NULL) AND operation IS DISTINCT FROM 'invoke_agent' THEN model END))), ', ') AS models,
  count(DISTINCT coalesce(prompt_id, generation_id)) AS prompts,
  count(DISTINCT CASE WHEN operation = 'execute_tool' THEN tool_call_id END)
    + count_if(operation = 'execute_tool' AND tool_call_id IS NULL AND signal = 'span') AS tool_calls,
  sum(CASE WHEN operation IS DISTINCT FROM 'invoke_agent' THEN input_tokens END) AS input_tokens,
  sum(CASE WHEN operation IS DISTINCT FROM 'invoke_agent' THEN output_tokens END) AS output_tokens,
  sum(cost_usd) AS cost_usd
FROM e
GROUP BY agent, person, session_id
HAVING min(ts) >= CAST({{since}} AS TIMESTAMP_NTZ)
ORDER BY min(ts) DESC
LIMIT 30
