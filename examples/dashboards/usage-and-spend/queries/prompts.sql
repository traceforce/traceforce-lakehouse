-- One row per prompt (turn) in one session, for the session drill-down. serve.py fills in the agent, person
-- (NULL for unattributed), session id and the session's start, which bounds the scan.
-- A turn runs from one user prompt to the next in the same session; every row in between (model calls,
-- tool calls, the response) is credited to it. This works for agents with no prompt id (Codex, Copilot).
-- Prompt and response text are the stored content: masked per the org's redaction policy, truncated here.
WITH src AS (
  SELECT
    lower(replace(e.agent, 'AGENT_IDENTITY_', '')) AS agent,
    coalesce(lower(e.user_email), lower(m.owner_email)) AS person,
    e.session_id, e.ts, e.event_name, e.signal, e.operation, e.model, e.tool_call_id,
    e.input_tokens, e.output_tokens, e.cost_usd, e.content_input, e.content_output,
    e.tool_name, e.mcp_server_name,
    regexp_replace(coalesce(e.mcp_server_name, ''), '[^A-Za-z0-9_-]', '_') AS server_key
  FROM agent_events e
  LEFT JOIN device_owner_mappings m ON m.device_native_id = e.device_native_id
  WHERE e.ts >= {{since}} AND e.session_id = {{session_id}}
    AND lower(replace(e.agent, 'AGENT_IDENTITY_', '')) = {{agent}}
    AND coalesce(lower(e.user_email), lower(m.owner_email)) IS NOT DISTINCT FROM {{person}}
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
-- Per call: Claude Code's decision and result rows say 'mcp_tool' and only its span names the tool, so a call
-- goes whole when any of its rows is the app's. An id-less row (a Copilot span) goes on its own flag.
ev AS (
  SELECT * FROM (
    SELECT flagged.*,
      -- ts only splits the id-less rows, whose value is unused, into small partitions.
      max(CASE WHEN app_call THEN 1 ELSE 0 END)
        OVER (PARTITION BY tool_call_id, operation, CASE WHEN tool_call_id IS NULL THEN ts END) AS call_app_call
    FROM flagged
  ) f
  WHERE NOT app_call AND (tool_call_id IS NULL OR call_app_call = 0)
),
txt AS (
  SELECT ev.*,
    -- Prompt rows: the agents' prompt events, and Copilot's chat spans (its only carrier of prompt text).
    CASE WHEN content_input IS NOT NULL
          AND (event_name IN ('user_prompt', 'beforeSubmitPrompt') OR (signal = 'span' AND operation = 'chat'))
      THEN coalesce(
        -- Text of the last user message in the JSON message array.
        try(array_join(transform(
          cast(json_extract(element_at(filter(cast(json_parse(content_input) AS array(json)),
                 x -> json_extract_scalar(x, '$.role') = 'user'), -1), '$.parts') AS array(json)),
          p -> coalesce(json_extract_scalar(p, '$.content'), '')), chr(10))),
        -- Unparseable log content is shown raw; a Copilot span with no user message continues the current turn.
        CASE WHEN signal = 'log' THEN content_input END)
    END AS prompt_text,
    CASE WHEN content_output IS NOT NULL
          AND (event_name IN ('assistant_response', 'afterAgentResponse', 'agent_response') OR (signal = 'span' AND operation = 'chat'))
      THEN coalesce(
        try(array_join(flatten(transform(
          filter(cast(json_parse(content_output) AS array(json)), x -> json_extract_scalar(x, '$.role') = 'assistant'),
          x -> transform(cast(json_extract(x, '$.parts') AS array(json)), p -> coalesce(json_extract_scalar(p, '$.content'), '')))),
          chr(10))),
        content_output)
    END AS response_text
  FROM ev
),
starts AS (
  SELECT txt.*,
    -- A Copilot tool loop repeats the same user message on every chat span: only a changed message starts a turn.
    prompt_text IS NOT NULL AND (signal = 'log' OR prompt_text IS DISTINCT FROM
      lag(prompt_text) OVER (PARTITION BY agent, person, session_id, prompt_text IS NOT NULL ORDER BY ts)) AS is_start
  FROM txt
),
turns AS (
  SELECT starts.*,
    max(CASE WHEN is_start THEN ts END) OVER (PARTITION BY agent, person, session_id ORDER BY ts
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS turn_ts
  FROM starts
)
SELECT
  agent, person, session_id,
  cast(turn_ts AS varchar) AS ts,
  cast(max(ts) AS varchar) AS ended_at,
  substr(max(CASE WHEN is_start AND ts = turn_ts THEN prompt_text END), 1, 4000) AS prompt,
  substr(max_by(response_text, CASE WHEN response_text IS NOT NULL THEN ts END), 1, 2000) AS response,
  array_join(array_sort(array_distinct(array_agg(
    CASE WHEN (input_tokens IS NOT NULL OR cost_usd IS NOT NULL) AND operation IS DISTINCT FROM 'invoke_agent' THEN model END))), ', ') AS models,
  count(DISTINCT CASE WHEN operation = 'execute_tool' THEN tool_call_id END)
    + count_if(operation = 'execute_tool' AND tool_call_id IS NULL AND signal = 'span') AS tool_calls,
  sum(CASE WHEN operation IS DISTINCT FROM 'invoke_agent' THEN input_tokens END) AS input_tokens,
  sum(CASE WHEN operation IS DISTINCT FROM 'invoke_agent' THEN output_tokens END) AS output_tokens,
  sum(cost_usd) AS cost_usd
FROM turns
WHERE turn_ts IS NOT NULL
GROUP BY agent, person, session_id, turn_ts
ORDER BY session_id, ts
