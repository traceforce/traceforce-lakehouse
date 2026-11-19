-- One person's tool calls per (UTC day, agent, tool), for the person drill-down's top tools.
-- serve.py fills in the person: an email, or NULL for unattributed activity.
-- A call is 1-3 rows sharing tool_call_id; Claude Code's decision/result rows say 'mcp_tool' and only its
-- span names the MCP tool, so take the most specific name per call. MCP calls are labeled server/tool.
WITH src AS (
  SELECT
    date(ev.ts) AS day,
    lower(replace(ev.agent, 'AGENT_IDENTITY_', '')) AS agent,
    coalesce(lower(ev.user_email), lower(m.owner_email)) AS person,
    ev.tool_call_id, ev.tool_name, ev.mcp_server_name, ev.signal, ev.operation,
    regexp_replace(coalesce(ev.mcp_server_name, ''), '[^A-Za-z0-9_-]', '_') AS server_key
  FROM agent_events ev
  LEFT JOIN device_owner_mappings m ON m.device_native_id = ev.device_native_id
  WHERE ev.ts >= date_add('day', -90, current_date) AND ev.operation = 'execute_tool'
    AND coalesce(lower(ev.user_email), lower(m.owner_email)) IS NOT DISTINCT FROM {{person}}
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
