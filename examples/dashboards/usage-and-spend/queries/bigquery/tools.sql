-- BigQuery (GoogleSQL) version of ../tools.sql: one person's tool calls per (UTC day, agent, tool).
WITH e AS (
  SELECT
    DATE(ev.ts) AS day,
    lower(replace(ev.agent, 'AGENT_IDENTITY_', '')) AS agent,
    coalesce(lower(ev.user_email), lower(m.owner_email)) AS person,
    ev.tool_call_id, ev.tool_name, ev.mcp_server_name, ev.signal
  FROM traceforce_lakehouse.agent_events ev
  LEFT JOIN traceforce_lakehouse.device_owner_mappings m ON m.device_native_id = ev.device_native_id
  WHERE ev.ts >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)) AND ev.operation = 'execute_tool'
    AND coalesce(lower(ev.user_email), lower(m.owner_email)) IS NOT DISTINCT FROM {{person}}
),
calls AS (
  SELECT min(day) AS day, agent, person,
         coalesce(max(CASE WHEN tool_name <> 'mcp_tool' THEN tool_name END), max(tool_name)) AS tool_name,
         max(mcp_server_name) AS mcp_server_name
  FROM e WHERE tool_call_id IS NOT NULL
  GROUP BY agent, person, tool_call_id
  UNION ALL
  SELECT day, agent, person, tool_name, mcp_server_name
  FROM e WHERE tool_call_id IS NULL AND signal = 'span'
)
SELECT
  CAST(day AS STRING) AS day, agent, person,
  CASE WHEN mcp_server_name IS NOT NULL THEN mcp_server_name || '/' || coalesce(tool_name, '?')
       ELSE coalesce(tool_name, 'unknown') END AS tool,
  count(*) AS calls
FROM calls
GROUP BY 1, 2, 3, 4
ORDER BY 1, 2, 3, 5 DESC
