-- Actions TraceForce blocked in the last 90 days, from the event logs (denied attempts never become findings).
-- The literals are agent behavior, per the skill's reference/enforcement.md; re-check them on a scout upgrade.
--   Claude Code tool call: tool_decision rejected by TraceForce's hook.
--   Cursor tool call: permission_denied tagged [Traceforce, with a containment mode stamped.
--   Claude Code prompt: user_prompt stamped sd_enforcement = 'block' with masked values (redaction on).
-- Copilot and Cowork blocks aren't observable in the lake, and Cursor prompt blocks leave no event.
WITH e AS (
  SELECT
    lower(replace(ev.agent, 'AGENT_IDENTITY_', '')) AS agent,
    coalesce(lower(ev.user_email), lower(m.owner_email)) AS person,
    ev.session_id, ev.ts, ev.tool_name, ev.tool_args, ev.mcp_server_name, ev.event_name,
    CASE
      WHEN ev.event_name = 'tool_decision' AND ev.decision = 'reject'
           AND json_extract_scalar(ev.attrs_json, '$.source') = 'hook' THEN 'tool_call'
      WHEN ev.event_name = 'postToolUseFailure' AND ev.error_type = 'permission_denied'
           AND json_extract_scalar(ev.attrs_json, '$["cursor.error.message"]') LIKE '%[Traceforce%'
           AND ev.containment_enforcement IN ('warn', 'block') THEN 'tool_call'
      WHEN ev.event_name = 'user_prompt' AND ev.sd_enforcement = 'block'
           AND ev.content_input LIKE '%********%' THEN 'prompt'
    END AS blocked
  FROM agent_events ev
  LEFT JOIN device_owner_mappings m ON m.device_native_id = ev.device_native_id
  WHERE ev.ts >= date_add('day', -90, current_date)
    AND ev.event_name IN ('tool_decision', 'postToolUseFailure', 'user_prompt')
)
SELECT
  cast(ts AS varchar) AS at, cast(date(ts) AS varchar) AS day, agent, person, session_id, blocked,
  CASE WHEN blocked = 'prompt' THEN 'prompt with sensitive data'
       WHEN mcp_server_name IS NOT NULL THEN mcp_server_name || '/' || coalesce(tool_name, '?')
       ELSE coalesce(tool_name, 'tool') END AS detail,
  substr(tool_args, 1, 600) AS tool_args
FROM e
WHERE blocked IS NOT NULL
ORDER BY ts
