-- Databricks SQL version of ../sessions.sql: one person's sessions in the last 90 days.
WITH src AS (
  SELECT
    lower(replace(ev.agent, 'AGENT_IDENTITY_', '')) AS agent,
    coalesce(lower(ev.user_email), lower(m.owner_email)) AS person,
    ev.session_id, ev.device_native_id, ev.ts, ev.model, ev.prompt_id, ev.generation_id, ev.tool_call_id,
    ev.signal, ev.operation, ev.input_tokens, ev.output_tokens, ev.cost_usd,
    ev.event_name, ev.tool_name, ev.mcp_server_name,
    regexp_replace(coalesce(ev.mcp_server_name, ''), '[^A-Za-z0-9_-]', '_') AS server_key
  FROM traceforce_lakehouse.traceforce.agent_events ev
  LEFT JOIN traceforce_lakehouse.traceforce.device_owner_mappings m ON m.device_native_id = ev.device_native_id
  WHERE ev.ts >= CAST(date_sub(to_date(timestampadd(MICROSECOND, unix_micros(current_timestamp()), TIMESTAMP_NTZ '1970-01-01 00:00:00')), 91) AS TIMESTAMP_NTZ)
    AND ev.session_id IS NOT NULL
    AND coalesce(lower(ev.user_email), lower(m.owner_email)) IS NOT DISTINCT FROM {{person}}
),
-- The agent app's calls that drive the app itself, not the person's work: scout's hostappmcp.IsHostAppMCP
-- (server_key spells the server as its mcpServerKey does), plus built-in plumbing. Keep the two in step.
flagged AS (
  SELECT src.*, coalesce(operation = 'execute_tool' AND (
    (agent IN ('claude', 'claude_code') AND (
      substr(server_key, 1, 4) = 'ccd_'
      OR server_key IN ('cowork', 'scheduled-tasks', 'hearthbot', 'claude-code-remote', 'Claude_Code_Remote',
                        'claude_ai_Claude_Docs', '1a59c906-04da-521d-bda7-7f71b9f9e01c')
      OR (server_key = 'visualize' AND tool_name IN ('show_widget', 'read_me'))
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
-- Per call: Claude Code's decision and result rows say 'mcp_tool' and only its span names the tool, so a call
-- goes whole when any of its rows is the app's. An id-less row (a Copilot span) goes on its own flag.
e AS (
  SELECT * FROM (
    SELECT flagged.*,
      -- session_id keeps Cursor's empty tool_call_id from linking calls across sessions;
      -- ts only splits the id-less rows, whose value is unused, into small partitions.
      max(CASE WHEN app_call THEN 1 ELSE 0 END)
        OVER (PARTITION BY session_id, tool_call_id, operation, CASE WHEN tool_call_id IS NULL THEN ts END) AS call_app_call
    FROM flagged
  ) f
  WHERE NOT app_call AND (tool_call_id IS NULL OR call_app_call = 0)
)
SELECT
  agent, person, session_id,
  any_value(device_native_id, true) AS device_native_id,
  CAST(min(ts) AS STRING) AS started_at,
  CAST(max(ts) AS STRING) AS ended_at,
  array_join(array_sort(array_distinct(collect_list(
    CASE WHEN (input_tokens IS NOT NULL OR cost_usd IS NOT NULL) AND operation IS DISTINCT FROM 'invoke_agent' THEN model END))), ', ') AS models,
  count(DISTINCT coalesce(prompt_id, generation_id))
    -- Codex's user_prompt rows carry neither id; ts tells them apart.
    + count(DISTINCT CASE WHEN event_name = 'user_prompt' AND prompt_id IS NULL AND generation_id IS NULL THEN ts END) AS prompts,
  count(DISTINCT CASE WHEN operation = 'execute_tool' THEN tool_call_id END)
    + count_if(operation = 'execute_tool' AND tool_call_id IS NULL AND signal = 'span') AS tool_calls,
  sum(CASE WHEN operation IS DISTINCT FROM 'invoke_agent' THEN input_tokens END) AS input_tokens,
  sum(CASE WHEN operation IS DISTINCT FROM 'invoke_agent' THEN output_tokens END) AS output_tokens,
  sum(cost_usd) AS cost_usd
FROM e
GROUP BY agent, person, session_id
HAVING min(ts) >= CAST(date_sub(to_date(timestampadd(MICROSECOND, unix_micros(current_timestamp()), TIMESTAMP_NTZ '1970-01-01 00:00:00')), 90) AS TIMESTAMP_NTZ)
  -- Hide noise sessions: no prompt, tool call, tokens, cost, TraceForce block or failed tool attempt (only startup, hook or connection events).
  -- e. keeps cost and tokens off the output aliases of the same name (BigQuery, Snowflake).
  AND (count_if(coalesce(prompt_id, generation_id) IS NOT NULL
        OR event_name IN ('user_prompt', 'beforeSubmitPrompt', 'traceforce.enforcement', 'postToolUseFailure') OR (signal = 'span' AND operation = 'chat')
        OR (operation = 'execute_tool' AND (tool_call_id IS NOT NULL OR signal = 'span'))) > 0
    OR coalesce(sum(e.cost_usd), 0) <> 0
    OR coalesce(sum(CASE WHEN operation IS DISTINCT FROM 'invoke_agent' THEN coalesce(e.input_tokens, 0) + coalesce(e.output_tokens, 0) END), 0) <> 0)
ORDER BY started_at
