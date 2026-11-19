-- Activity with no person (no email on the event, no MDM owner for the device), per (UTC day, agent, device serial).
-- Sums to the dashboard's "Unattributed" bucket, so the device breakdown agrees with the totals.
WITH src AS (
  SELECT date(ev.ts) AS day, lower(replace(ev.agent, 'AGENT_IDENTITY_', '')) AS agent,
         coalesce(ev.device_native_id, 'unknown') AS device_native_id,
         ev.ts, ev.session_id, ev.tool_call_id, ev.signal, ev.operation, ev.input_tokens, ev.output_tokens, ev.cost_usd,
         ev.prompt_id, ev.generation_id, ev.event_name, ev.tool_name, ev.mcp_server_name,
         regexp_replace(coalesce(ev.mcp_server_name, ''), '[^A-Za-z0-9_-]', '_') AS server_key
  FROM agent_events ev
  LEFT JOIN device_owner_mappings m ON m.device_native_id = ev.device_native_id
  WHERE ev.ts >= date_add('day', -90, current_date)
    AND ev.user_email IS NULL AND m.owner_email IS NULL
),
-- The agent app's calls that drive the app itself, not the person's work: scout's hostappmcp.IsHostAppMCP
-- (server_key spells the server as its mcpServerKey does), plus built-in plumbing. Keep the two in step.
flagged AS (
  SELECT src.*, coalesce(operation = 'execute_tool' AND (
    (agent IN ('claude', 'claude_code') AND (
      substr(server_key, 1, 4) = 'ccd_'
      OR server_key IN ('cowork', 'scheduled-tasks', 'hearthbot', 'claude-code-remote', 'Claude_Code_Remote',
                        'claude_ai_Claude_Docs', '1a59c906-04da-521d-bda7-7f71b9f9e01c', 'visualize')
      OR (server_key IN ('Claude_Browser', 'Claude_Preview') AND tool_name IN ('preview_start', 'preview_stop', 'preview_list', 'preview_logs'))
      OR (server_key = 'terminal' AND tool_name IN ('read_terminal', 'open_terminal_tab', 'list_terminal_tabs', 'stop_terminal_tab'))
      OR (server_key = 'memory' AND tool_name IN ('memory_read', 'memory_list', 'memory_write', 'memory_str_replace', 'memory_append', 'memory_delete'))))
    OR (agent = 'chatgpt_codex' AND (
      replace(server_key, '-', '_') IN ('codex_app', 'codex_security')
      OR (replace(server_key, '-', '_') IN ('node_repl', 'cua_repl') AND tool_name IN ('js_reset', 'js_add_node_module_dir'))
      OR (replace(server_key, '-', '_') = 'codex_apps' AND regexp_replace(regexp_replace(tool_name, '^.*__', ''), '^_+', '')
          IN ('web_run', 'write_page_reference', 'create_plugin', 'update_app_permissions', 'save_site_version', 'create_source_repository_write_credential'))))
    OR (agent = 'cursor' AND ((server_key = '' AND tool_name IN ('move_agent_to_root', 'move_agent_to_cloned_root'))
      OR server_key IN ('cursor-app-control', 'cursor-backend-control', 'cursor-subscriptions')))
    -- Built-in plumbing with no server: tool search, structured output, subagent handback, Claude's compose and present.
    OR (server_key = '' AND tool_name IN ('ToolSearch', 'StructuredOutput', 'SubagentHandback', 'tool_search', 'tool_search_tool', 'message_compose_v1', 'present_files'))), false) AS app_call
  FROM src
),
-- Per call: Claude Code's decision and result rows say 'mcp_tool' and only its span names the tool.
e AS (
  SELECT f.* FROM flagged f
  LEFT JOIN (SELECT DISTINCT tool_call_id FROM flagged WHERE app_call) a
    ON a.tool_call_id = f.tool_call_id AND f.operation = 'execute_tool'
  WHERE NOT f.app_call AND a.tool_call_id IS NULL
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
        FROM e WHERE session_id IS NOT NULL GROUP BY agent, device_native_id, session_id
        -- Hide noise sessions: no prompt, tool call, tokens, cost, TraceForce block or failed tool attempt (only startup, hook or connection events).
        HAVING (count(coalesce(prompt_id, generation_id)) > 0
          OR count_if(event_name IN ('user_prompt', 'beforeSubmitPrompt', 'traceforce.enforcement', 'postToolUseFailure') OR (signal = 'span' AND operation = 'chat')) > 0
          OR count(DISTINCT CASE WHEN operation = 'execute_tool' THEN tool_call_id END)
            + count_if(operation = 'execute_tool' AND tool_call_id IS NULL AND signal = 'span') > 0
          OR coalesce(sum(e.cost_usd), 0) <> 0
          OR coalesce(sum(CASE WHEN operation IS DISTINCT FROM 'invoke_agent' THEN coalesce(e.input_tokens, 0) + coalesce(e.output_tokens, 0) END), 0) <> 0))
  GROUP BY 1, 2, 3
)
SELECT cast(coalesce(u.day, s.day) AS varchar) AS day, coalesce(u.agent, s.agent) AS agent,
       coalesce(u.device_native_id, s.device_native_id) AS device_native_id,
       coalesce(s.sessions, 0) AS sessions, coalesce(u.tool_calls, 0) AS tool_calls, u.tokens, u.cost_usd
FROM usage u
FULL OUTER JOIN sessions s ON s.day = u.day AND s.agent = u.agent AND s.device_native_id = u.device_native_id
-- Rows left all zero (only hidden sessions) would show people and devices with no activity.
WHERE coalesce(s.sessions, 0) + coalesce(u.tool_calls, 0) > 0
  OR coalesce(u.tokens, 0) <> 0
  OR coalesce(u.cost_usd, 0) <> 0
ORDER BY 1, 2, 3
