-- BigQuery (GoogleSQL) version of ../blocks.sql: actions TraceForce blocked in the last 90 days.
-- Also in traceforce-ui src/lib/lakehouse/queries/incidents.ts (the in-app GCP dashboards): keep the two in sync.
WITH e AS (
  SELECT
    lower(replace(ev.agent, 'AGENT_IDENTITY_', '')) AS agent,
    coalesce(lower(ev.user_email), lower(m.owner_email)) AS person,
    ev.session_id, ev.ts, ev.tool_call_id, ev.tool_name, ev.tool_args, ev.mcp_server_name, ev.event_name,
    CASE
      WHEN ev.event_name = 'tool_decision' AND ev.decision = 'reject'
           AND JSON_VALUE(ev.attrs_json, '$.source') = 'hook' THEN 'tool_call'
      WHEN ev.event_name = 'postToolUseFailure' AND ev.error_type = 'permission_denied'
           AND JSON_VALUE(ev.attrs_json, '$."cursor.error.message"') LIKE '%[Traceforce%'
           AND ev.containment_enforcement IN ('warn', 'block') THEN 'tool_call'
      WHEN ev.event_name = 'user_prompt' AND ev.sd_enforcement = 'block'
           AND ev.content_input LIKE '%********%' THEN 'prompt'
    END AS blocked
  FROM traceforce_lakehouse.agent_events ev
  LEFT JOIN traceforce_lakehouse.device_owner_mappings m ON m.device_native_id = ev.device_native_id
  WHERE ev.ts >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY))
    AND ev.event_name IN ('tool_decision', 'postToolUseFailure', 'user_prompt')
),
-- A blocked call's other rows can hold the arguments its own row lacks (a denied Read's span); ranked as in timeline.sql.
call_args AS (
  SELECT session_id, tool_call_id,
    substr(max(CASE WHEN tool_args IS NOT NULL THEN concat(CASE WHEN event_name = 'tool_result' THEN '9' WHEN event_name = 'tool_call' THEN '8'
      WHEN event_name IN ('postToolUse', 'postToolUseFailure') THEN '7' WHEN event_name = 'afterMCPExecution' THEN '6'
      WHEN event_name = 'preToolUse' THEN '5' WHEN signal = 'span' THEN '4' WHEN event_name = 'tool_decision' THEN '1' ELSE '2' END, tool_args) END), 2) AS args
  FROM traceforce_lakehouse.agent_events
  WHERE ts >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY))
    AND tool_call_id IN (SELECT tool_call_id FROM e WHERE blocked = 'tool_call')
  GROUP BY session_id, tool_call_id
)
SELECT
  FORMAT_TIMESTAMP('%F %H:%M:%E6S', ts) AS `at`, CAST(DATE(ts) AS STRING) AS day, agent, person, e.session_id AS session_id, blocked,
  CASE WHEN blocked = 'prompt' THEN 'prompt with sensitive data'
       WHEN mcp_server_name IS NOT NULL THEN mcp_server_name || '/' || coalesce(tool_name, '?')
       ELSE coalesce(tool_name, 'tool') END AS detail,
  substr(coalesce(c.args, e.tool_args), 1, 600) AS tool_args
FROM e
LEFT JOIN call_args c ON c.session_id = e.session_id AND c.tool_call_id = e.tool_call_id
WHERE blocked IS NOT NULL
ORDER BY e.ts
