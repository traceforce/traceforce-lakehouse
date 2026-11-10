-- One person's sessions (agent, person, session_id) started in the last 90 days, for the person drill-down.
-- Person as in activity.sql; serve.py fills it in: an email, or NULL for unattributed activity,
-- whose device_native_id lets it be traced to a device.
WITH e AS (
  SELECT
    lower(replace(ev.agent, 'AGENT_IDENTITY_', '')) AS agent,
    coalesce(lower(ev.user_email), lower(m.owner_email)) AS person,
    ev.session_id, ev.device_native_id, ev.ts, ev.model, ev.prompt_id, ev.generation_id, ev.tool_call_id,
    ev.signal, ev.operation, ev.input_tokens, ev.output_tokens, ev.cost_usd
  FROM agent_events ev
  LEFT JOIN device_owner_mappings m ON m.device_native_id = ev.device_native_id
  WHERE ev.ts >= date_add('day', -91, current_date) AND ev.session_id IS NOT NULL
    AND coalesce(lower(ev.user_email), lower(m.owner_email)) IS NOT DISTINCT FROM {{person}}
)
SELECT
  agent, person, session_id,
  arbitrary(device_native_id) AS device_native_id,
  cast(min(ts) AS varchar) AS started_at,
  cast(max(ts) AS varchar) AS ended_at,
  -- Models that served billed/tokened turns; selectors such as 'auto' are not model names.
  array_join(array_sort(array_distinct(array_agg(
    CASE WHEN (input_tokens IS NOT NULL OR cost_usd IS NOT NULL) AND operation IS DISTINCT FROM 'invoke_agent' THEN model END))), ', ') AS models,
  count(DISTINCT coalesce(prompt_id, generation_id)) AS prompts,
  count(DISTINCT CASE WHEN operation = 'execute_tool' THEN tool_call_id END)
    + count_if(operation = 'execute_tool' AND tool_call_id IS NULL AND signal = 'span') AS tool_calls,
  sum(CASE WHEN operation IS DISTINCT FROM 'invoke_agent' THEN input_tokens END) AS input_tokens,
  sum(CASE WHEN operation IS DISTINCT FROM 'invoke_agent' THEN output_tokens END) AS output_tokens,
  sum(cost_usd) AS cost_usd
FROM e
GROUP BY agent, person, session_id
HAVING min(ts) >= date_add('day', -90, current_date)
ORDER BY started_at
