-- BigQuery (GoogleSQL) version of ../recent_sessions.sql: the 30 most recent sessions across everyone.
-- Also in traceforce-ui src/lib/lakehouse/queries/usage.ts (the in-app GCP dashboards): keep the two in sync.
WITH src AS (
  SELECT
    lower(replace(ev.agent, 'AGENT_IDENTITY_', '')) AS agent,
    coalesce(lower(ev.user_email), lower(m.owner_email)) AS person,
    ev.session_id, ev.device_native_id, ev.ts, ev.model, ev.prompt_id, ev.generation_id, ev.tool_call_id,
    ev.signal, ev.operation, ev.input_tokens, ev.output_tokens, ev.cost_usd,
    -- Models that served billed/tokened turns; selectors such as 'auto' are not model names.
    CASE WHEN (ev.input_tokens IS NOT NULL OR ev.cost_usd IS NOT NULL) AND ev.operation IS DISTINCT FROM 'invoke_agent'
      THEN ev.model END AS billed_model,
      ev.event_name, ev.tool_name, ev.mcp_server_name,
      regexp_replace(coalesce(ev.mcp_server_name, ''), '[^A-Za-z0-9_-]', '_') AS server_key
  FROM traceforce_lakehouse.agent_events ev
  LEFT JOIN traceforce_lakehouse.device_owner_mappings m ON m.device_native_id = ev.device_native_id
  -- A day of slack so a session's events just before its start still count; HAVING drops older starts.
  WHERE ev.ts >= TIMESTAMP_SUB({{since}}, INTERVAL 1 DAY) AND ev.session_id IS NOT NULL
    -- The CAST because BigQuery rejects "= NULL" even where it can't match.
    AND ({{agent}} IS NULL OR lower(replace(ev.agent, 'AGENT_IDENTITY_', '')) = CAST({{agent}} AS STRING))
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
)
SELECT
  agent, person, session_id,
  ANY_VALUE(device_native_id) AS device_native_id,
  FORMAT_TIMESTAMP('%F %H:%M:%E6S', min(ts)) AS started_at,
  FORMAT_TIMESTAMP('%F %H:%M:%E6S', max(ts)) AS ended_at,
  STRING_AGG(DISTINCT billed_model, ', ' ORDER BY billed_model) AS models,
  count(DISTINCT coalesce(prompt_id, generation_id))
    -- Codex's user_prompt rows carry neither id; ts tells them apart.
    + count(DISTINCT CASE WHEN event_name = 'user_prompt' AND prompt_id IS NULL AND generation_id IS NULL THEN ts END) AS prompts,
  count(DISTINCT CASE WHEN operation = 'execute_tool' THEN tool_call_id END)
    + COUNTIF(operation = 'execute_tool' AND tool_call_id IS NULL AND signal = 'span') AS tool_calls,
  sum(CASE WHEN operation IS DISTINCT FROM 'invoke_agent' THEN input_tokens END) AS input_tokens,
  sum(CASE WHEN operation IS DISTINCT FROM 'invoke_agent' THEN output_tokens END) AS output_tokens,
  sum(cost_usd) AS cost_usd
FROM e
GROUP BY agent, person, session_id
HAVING min(ts) >= {{since}}
  -- Hide noise sessions: no prompt, tool call, tokens or cost (only startup, hook or connection events).
  -- e. keeps cost and tokens off the output aliases of the same name (BigQuery, Snowflake).
  AND (count(coalesce(prompt_id, generation_id)) > 0
    OR COUNTIF(event_name IN ('user_prompt', 'beforeSubmitPrompt') OR (signal = 'span' AND operation = 'chat')) > 0
    OR count(DISTINCT CASE WHEN operation = 'execute_tool' THEN tool_call_id END)
      + COUNTIF(operation = 'execute_tool' AND tool_call_id IS NULL AND signal = 'span') > 0
    OR coalesce(sum(e.cost_usd), 0) <> 0
    OR coalesce(sum(CASE WHEN operation IS DISTINCT FROM 'invoke_agent' THEN coalesce(e.input_tokens, 0) + coalesce(e.output_tokens, 0) END), 0) <> 0)
ORDER BY min(ts) DESC
LIMIT 30
