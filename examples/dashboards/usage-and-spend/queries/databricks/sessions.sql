-- Databricks SQL version of ../sessions.sql: one person's sessions in the last 90 days.
WITH e AS (
  SELECT
    lower(replace(ev.agent, 'AGENT_IDENTITY_', '')) AS agent,
    coalesce(lower(ev.user_email), lower(m.owner_email)) AS person,
    ev.session_id, ev.device_native_id, ev.ts, ev.model, ev.prompt_id, ev.generation_id, ev.tool_call_id,
    ev.signal, ev.operation, ev.input_tokens, ev.output_tokens, ev.cost_usd
  FROM traceforce_lakehouse.traceforce.agent_events ev
  LEFT JOIN traceforce_lakehouse.traceforce.device_owner_mappings m ON m.device_native_id = ev.device_native_id
  WHERE ev.ts >= CAST(date_sub(to_date(timestampadd(MICROSECOND, unix_micros(current_timestamp()), TIMESTAMP_NTZ '1970-01-01 00:00:00')), 91) AS TIMESTAMP_NTZ)
    AND ev.session_id IS NOT NULL
    AND coalesce(lower(ev.user_email), lower(m.owner_email)) IS NOT DISTINCT FROM {{person}}
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
HAVING min(ts) >= CAST(date_sub(to_date(timestampadd(MICROSECOND, unix_micros(current_timestamp()), TIMESTAMP_NTZ '1970-01-01 00:00:00')), 90) AS TIMESTAMP_NTZ)
ORDER BY started_at
