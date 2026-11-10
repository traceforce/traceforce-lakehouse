-- BigQuery (GoogleSQL) version of ../activity.sql: one row per (UTC day, agent, person).
-- Also in traceforce-ui src/lib/lakehouse/queries/usage.ts (the in-app GCP dashboards): keep the two in sync.
WITH e AS (
  SELECT
    DATE(ev.ts) AS day,
    lower(replace(ev.agent, 'AGENT_IDENTITY_', '')) AS agent,
    coalesce(lower(ev.user_email), lower(m.owner_email)) AS person,
    ev.ts, ev.session_id, ev.prompt_id, ev.generation_id, ev.tool_call_id,
    ev.signal, ev.operation, ev.input_tokens, ev.output_tokens, ev.cache_read_tokens, ev.cost_usd
  FROM traceforce_lakehouse.agent_events ev
  LEFT JOIN traceforce_lakehouse.device_owner_mappings m ON m.device_native_id = ev.device_native_id
  WHERE ev.ts >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY))
),
usage AS (
  SELECT
    day, agent, person,
    count(DISTINCT coalesce(prompt_id, generation_id)) AS prompts,
    count(DISTINCT CASE WHEN operation = 'execute_tool' THEN tool_call_id END)
      + COUNTIF(operation = 'execute_tool' AND tool_call_id IS NULL AND signal = 'span') AS tool_calls,
    sum(CASE WHEN operation IS DISTINCT FROM 'invoke_agent' THEN input_tokens END) AS input_tokens,
    sum(CASE WHEN operation IS DISTINCT FROM 'invoke_agent' THEN output_tokens END) AS output_tokens,
    sum(CASE WHEN operation IS DISTINCT FROM 'invoke_agent' THEN cache_read_tokens END) AS cache_read_tokens,
    sum(cost_usd) AS cost_usd
  FROM e
  GROUP BY 1, 2, 3
),
sessions AS (
  SELECT day, agent, person, count(*) AS sessions
  FROM (
    SELECT DATE(min(ts)) AS day, agent, person, session_id
    FROM e WHERE session_id IS NOT NULL
    GROUP BY agent, person, session_id
  )
  GROUP BY 1, 2, 3
)
SELECT
  CAST(coalesce(u.day, s.day) AS STRING) AS day,
  coalesce(u.agent, s.agent) AS agent,
  coalesce(u.person, s.person) AS person,
  coalesce(s.sessions, 0) AS sessions,
  coalesce(u.prompts, 0) AS prompts,
  coalesce(u.tool_calls, 0) AS tool_calls,
  u.input_tokens, u.output_tokens, u.cache_read_tokens, u.cost_usd
FROM usage u
FULL OUTER JOIN sessions s
  ON s.day = u.day AND s.agent = u.agent AND s.person IS NOT DISTINCT FROM u.person
ORDER BY 1, 2, 3
