-- Databricks SQL version of ../blocks.sql: actions TraceForce blocked in the last 90 days.
-- get_json_object needs a dotted key in brackets ($["cursor.error.message"]), as json_extract_scalar does.
WITH src AS (
  SELECT
    lower(replace(ev.agent, 'AGENT_IDENTITY_', '')) AS agent,
    coalesce(lower(ev.user_email), lower(m.owner_email)) AS person,
    ev.session_id, ev.ts, ev.tool_call_id, ev.tool_name, ev.tool_args, ev.mcp_server_name, ev.event_name,
    CASE
      WHEN ev.event_name = 'tool_decision' AND ev.decision = 'reject'
           AND get_json_object(ev.attrs_json, '$.source') = 'hook' THEN 'tool_call'
      WHEN ev.event_name = 'postToolUseFailure' AND ev.error_type = 'permission_denied'
           AND get_json_object(ev.attrs_json, '$["cursor.error.message"]') LIKE '%[Traceforce%'
           AND ev.containment_enforcement IN ('warn', 'block') THEN 'tool_call'
      WHEN ev.event_name = 'user_prompt' AND ev.sd_enforcement = 'block'
           AND ev.content_input LIKE '%********%' THEN 'prompt'
    END AS blocked,
    -- A blocked call's other rows can hold the arguments its own row lacks (a denied Read's span); ranked as in timeline.sql.
    CASE WHEN ev.tool_args IS NOT NULL THEN concat(CASE WHEN ev.event_name = 'tool_result' THEN '9' WHEN ev.event_name = 'tool_call' THEN '8'
      WHEN ev.event_name IN ('postToolUse', 'postToolUseFailure') THEN '7' WHEN ev.event_name = 'afterMCPExecution' THEN '6'
      WHEN ev.event_name = 'preToolUse' THEN '5' WHEN ev.signal = 'span' THEN '4' WHEN ev.event_name = 'tool_decision' THEN '1' ELSE '2' END, ev.tool_args) END AS ranked_args
  FROM traceforce_lakehouse.traceforce.agent_events ev
  LEFT JOIN traceforce_lakehouse.traceforce.device_owner_mappings m ON m.device_native_id = ev.device_native_id
  WHERE ev.ts >= CAST(date_sub(to_date(timestampadd(MICROSECOND, unix_micros(current_timestamp()), TIMESTAMP_NTZ '1970-01-01 00:00:00')), 90) AS TIMESTAMP_NTZ)
    AND (ev.event_name IN ('tool_decision', 'postToolUseFailure', 'user_prompt') OR ev.tool_call_id IS NOT NULL)
),
e AS (
  SELECT src.*,
    CASE WHEN blocked = 'tool_call' AND session_id IS NOT NULL AND tool_call_id IS NOT NULL
      THEN substr(max(ranked_args) OVER (PARTITION BY session_id, tool_call_id), 2) END AS args
  FROM src
)
SELECT
  CAST(ts AS STRING) AS at, CAST(to_date(ts) AS STRING) AS day, agent, person, session_id, blocked,
  CASE WHEN blocked = 'prompt' THEN 'prompt with sensitive data'
       WHEN mcp_server_name IS NOT NULL THEN mcp_server_name || '/' || coalesce(tool_name, '?')
       ELSE coalesce(tool_name, 'tool') END AS detail,
  substr(coalesce(args, tool_args), 1, 600) AS tool_args
FROM e
WHERE blocked IS NOT NULL
ORDER BY ts
