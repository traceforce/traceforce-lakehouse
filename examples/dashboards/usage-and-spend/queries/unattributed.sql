-- Activity with no person (no email on the event, no MDM owner for the device), per (UTC day, agent, device serial).
-- Sums to the dashboard's "Unattributed" bucket, so the device breakdown agrees with the totals.
WITH e AS (
  SELECT date(ev.ts) AS day, lower(replace(ev.agent, 'AGENT_IDENTITY_', '')) AS agent,
         coalesce(ev.device_native_id, 'unknown') AS device_native_id,
         ev.ts, ev.session_id, ev.tool_call_id, ev.signal, ev.operation, ev.input_tokens, ev.output_tokens, ev.cost_usd
  FROM agent_events ev
  LEFT JOIN device_owner_mappings m ON m.device_native_id = ev.device_native_id
  WHERE ev.ts >= date_add('day', -90, current_date)
    AND ev.user_email IS NULL AND m.owner_email IS NULL
),
usage AS (
  SELECT day, agent, device_native_id,
         count(DISTINCT CASE WHEN operation = 'execute_tool' THEN tool_call_id END)
           + count_if(operation = 'execute_tool' AND tool_call_id IS NULL AND signal = 'span') AS tool_calls,
         sum(CASE WHEN operation IS DISTINCT FROM 'invoke_agent' THEN coalesce(input_tokens, 0) + coalesce(output_tokens, 0) END) AS tokens,
         sum(cost_usd) AS cost_usd
  FROM e GROUP BY 1, 2, 3
),
sessions AS (
  SELECT day, agent, device_native_id, count(*) AS sessions
  FROM (SELECT date(min(ts)) AS day, agent, device_native_id, session_id
        FROM e WHERE session_id IS NOT NULL GROUP BY agent, device_native_id, session_id)
  GROUP BY 1, 2, 3
)
SELECT cast(coalesce(u.day, s.day) AS varchar) AS day, coalesce(u.agent, s.agent) AS agent,
       coalesce(u.device_native_id, s.device_native_id) AS device_native_id,
       coalesce(s.sessions, 0) AS sessions, coalesce(u.tool_calls, 0) AS tool_calls, u.tokens, u.cost_usd
FROM usage u
FULL OUTER JOIN sessions s ON s.day = u.day AND s.agent = u.agent AND s.device_native_id = u.device_native_id
ORDER BY 1, 2, 3
