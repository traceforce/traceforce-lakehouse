-- One person's tool calls per (UTC day, agent, tool), for the person drill-down's top tools.
-- serve.py fills in the person: an email, or NULL for unattributed activity.
-- A call is 1-3 rows sharing tool_call_id; Claude Code's decision/result rows say 'mcp_tool' and only its
-- span names the MCP tool, so take the most specific name per call. MCP calls are labeled server/tool.
WITH e AS (
  SELECT
    date(ev.ts) AS day,
    lower(replace(ev.agent, 'AGENT_IDENTITY_', '')) AS agent,
    coalesce(lower(ev.user_email), lower(m.owner_email)) AS person,
    ev.tool_call_id, ev.tool_name, ev.mcp_server_name, ev.signal
  FROM agent_events ev
  LEFT JOIN device_owner_mappings m ON m.device_native_id = ev.device_native_id
  WHERE ev.ts >= date_add('day', -90, current_date) AND ev.operation = 'execute_tool'
    AND coalesce(lower(ev.user_email), lower(m.owner_email)) IS NOT DISTINCT FROM {{person}}
),
calls AS (
  SELECT min(day) AS day, agent, person,
         coalesce(max(CASE WHEN tool_name <> 'mcp_tool' THEN tool_name END), max(tool_name)) AS tool_name,
         max(mcp_server_name) AS mcp_server_name
  FROM e WHERE tool_call_id IS NOT NULL
  GROUP BY agent, person, tool_call_id
  UNION ALL
  -- Copilot's tool spans carry no id: one span, one call.
  SELECT day, agent, person, tool_name, mcp_server_name
  FROM e WHERE tool_call_id IS NULL AND signal = 'span'
)
SELECT
  cast(day AS varchar) AS day, agent, person,
  CASE WHEN mcp_server_name IS NOT NULL THEN mcp_server_name || '/' || coalesce(tool_name, '?')
       ELSE coalesce(tool_name, 'unknown') END AS tool,
  count(*) AS calls
FROM calls
GROUP BY 1, 2, 3, 4
ORDER BY 1, 2, 3, 5 DESC
