-- BigQuery (GoogleSQL) version of ../sessions.sql: one person's sessions in the last 90 days.
-- Also in traceforce-ui src/lib/lakehouse/queries/usage.ts (the in-app GCP dashboards): keep the two in sync.
WITH e AS (
  SELECT
    lower(replace(ev.agent, 'AGENT_IDENTITY_', '')) AS agent,
    coalesce(lower(ev.user_email), lower(m.owner_email)) AS person,
    ev.session_id, ev.device_native_id, ev.ts, ev.model, ev.prompt_id, ev.generation_id, ev.tool_call_id,
    ev.signal, ev.operation, ev.input_tokens, ev.output_tokens, ev.cost_usd,
    -- Models that served billed/tokened turns; selectors such as 'auto' are not model names.
    CASE WHEN (ev.input_tokens IS NOT NULL OR ev.cost_usd IS NOT NULL) AND ev.operation IS DISTINCT FROM 'invoke_agent'
      THEN ev.model END AS billed_model
  FROM traceforce_lakehouse.agent_events ev
  LEFT JOIN traceforce_lakehouse.device_owner_mappings m ON m.device_native_id = ev.device_native_id
  WHERE ev.ts >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 91 DAY)) AND ev.session_id IS NOT NULL
    AND coalesce(lower(ev.user_email), lower(m.owner_email)) IS NOT DISTINCT FROM {{person}}
)
SELECT
  agent, person, session_id,
  ANY_VALUE(device_native_id) AS device_native_id,
  FORMAT_TIMESTAMP('%F %H:%M:%E6S', min(ts)) AS started_at,
  FORMAT_TIMESTAMP('%F %H:%M:%E6S', max(ts)) AS ended_at,
  STRING_AGG(DISTINCT billed_model, ', ' ORDER BY billed_model) AS models,
  count(DISTINCT coalesce(prompt_id, generation_id)) AS prompts,
  count(DISTINCT CASE WHEN operation = 'execute_tool' THEN tool_call_id END)
    + COUNTIF(operation = 'execute_tool' AND tool_call_id IS NULL AND signal = 'span') AS tool_calls,
  sum(CASE WHEN operation IS DISTINCT FROM 'invoke_agent' THEN input_tokens END) AS input_tokens,
  sum(CASE WHEN operation IS DISTINCT FROM 'invoke_agent' THEN output_tokens END) AS output_tokens,
  sum(cost_usd) AS cost_usd
FROM e
GROUP BY agent, person, session_id
HAVING min(ts) >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY))
ORDER BY started_at
