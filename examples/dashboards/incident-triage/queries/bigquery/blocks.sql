-- BigQuery (GoogleSQL) version of ../blocks.sql: actions TraceForce blocked in the last 90 days.
WITH e AS (
  SELECT
    lower(replace(ev.agent, 'AGENT_IDENTITY_', '')) AS agent,
    coalesce(lower(ev.user_email), lower(m.owner_email)) AS person,
    ev.session_id, ev.ts, ev.tool_name, ev.tool_args, ev.mcp_server_name, ev.event_name,
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
)
SELECT
  FORMAT_TIMESTAMP('%F %H:%M:%E6S', ts) AS `at`, CAST(DATE(ts) AS STRING) AS day, agent, person, session_id, blocked,
  CASE WHEN blocked = 'prompt' THEN 'prompt with sensitive data'
       WHEN mcp_server_name IS NOT NULL THEN mcp_server_name || '/' || coalesce(tool_name, '?')
       ELSE coalesce(tool_name, 'tool') END AS detail,
  substr(tool_args, 1, 600) AS tool_args
FROM e
WHERE blocked IS NOT NULL
ORDER BY e.ts
