-- Databricks SQL version of ../prompts.sql: one row per prompt (turn) in one session.
-- The message arrays are read as VARIANT, as close to Trino's try(json_parse ...) as Databricks allows:
-- an unpaired UTF-16 surrogate escape (half an emoji) would make the whole text unparseable, so it is
-- retried with only the unpaired escapes as U+FFFD (whole emoji kept; escaped backslashes are set
-- aside as U+0001 first, so \\ud83d stays literal text; text that already holds a raw U+0001, invalid
-- JSON, isn't retried); a
-- part's content that is an object or array counts as no text, as json_extract_scalar does; a message
-- without parts is skipped; try_element_at gives NULL for an empty array.
WITH src AS (
  SELECT
    lower(replace(e.agent, 'AGENT_IDENTITY_', '')) AS agent,
    coalesce(lower(e.user_email), lower(m.owner_email)) AS person,
    e.session_id, e.ts, e.event_name, e.signal, e.operation, e.model, e.tool_call_id,
    e.input_tokens, e.output_tokens, e.cost_usd, e.content_input, e.content_output,
    e.tool_name, e.mcp_server_name,
    regexp_replace(coalesce(e.mcp_server_name, ''), '[^A-Za-z0-9_-]', '_') AS server_key
  FROM traceforce_lakehouse.traceforce.agent_events e
  LEFT JOIN traceforce_lakehouse.traceforce.device_owner_mappings m ON m.device_native_id = e.device_native_id
  WHERE e.ts >= CAST({{since}} AS TIMESTAMP_NTZ) AND e.session_id = {{session_id}}
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
-- Per call: Claude Code's decision and result rows say 'mcp_tool' and only its span names the tool.
ev AS (
  SELECT f.* FROM flagged f
  LEFT JOIN (SELECT DISTINCT tool_call_id FROM flagged WHERE app_call) a
    ON a.tool_call_id = f.tool_call_id AND f.operation = 'execute_tool'
  WHERE NOT f.app_call AND a.tool_call_id IS NULL
),
txt AS (
  SELECT ev.*,
    -- Prompt rows: the agents' prompt events, and Copilot's chat spans (its only carrier of prompt text).
    CASE WHEN content_input IS NOT NULL
          AND (event_name IN ('user_prompt', 'beforeSubmitPrompt') OR (signal = 'span' AND operation = 'chat'))
      THEN coalesce(
        -- Text of the last user message in the JSON message array.
        array_join(transform(
          try_variant_get(
            try_element_at(filter(try_variant_get(coalesce(try_parse_json(content_input), CASE WHEN instr(content_input, char(1)) = 0 THEN try_parse_json(replace(regexp_replace(regexp_replace(replace(content_input, concat(char(92), char(92)), char(1)), r'\\u[dD][89abAB][0-9a-fA-F]{2}(?!\\u[dD][c-fC-F][0-9a-fA-F]{2})', r'\\ufffd'), r'(?<!\\u[dD][89abAB][0-9a-fA-F]{2})\\u[dD][c-fC-F][0-9a-fA-F]{2}', r'\\ufffd'), char(1), concat(char(92), char(92)))) END), '$', 'array<variant>'),
                                  x -> try_variant_get(x, '$.role', 'string') = 'user'), -1),
            '$.parts', 'array<variant>'),
          p -> coalesce(CASE WHEN schema_of_variant(try_variant_get(p, '$.content', 'variant')) RLIKE '^(OBJECT|ARRAY)' THEN NULL
                    ELSE try_variant_get(p, '$.content', 'string') END, '')), char(10)),
        -- Unparseable log content is shown raw; a Copilot span with no user message continues the current turn.
        CASE WHEN signal = 'log' THEN content_input END)
    END AS prompt_text,
    CASE WHEN content_output IS NOT NULL
          AND (event_name IN ('assistant_response', 'afterAgentResponse', 'agent_response') OR (signal = 'span' AND operation = 'chat'))
      THEN coalesce(
        -- Text of every assistant message in the JSON message array.
        array_join(flatten(filter(transform(
          filter(try_variant_get(coalesce(try_parse_json(content_output), CASE WHEN instr(content_output, char(1)) = 0 THEN try_parse_json(replace(regexp_replace(regexp_replace(replace(content_output, concat(char(92), char(92)), char(1)), r'\\u[dD][89abAB][0-9a-fA-F]{2}(?!\\u[dD][c-fC-F][0-9a-fA-F]{2})', r'\\ufffd'), r'(?<!\\u[dD][89abAB][0-9a-fA-F]{2})\\u[dD][c-fC-F][0-9a-fA-F]{2}', r'\\ufffd'), char(1), concat(char(92), char(92)))) END), '$', 'array<variant>'),
                 x -> try_variant_get(x, '$.role', 'string') = 'assistant'),
          x -> transform(try_variant_get(x, '$.parts', 'array<variant>'),
                         p -> coalesce(CASE WHEN schema_of_variant(try_variant_get(p, '$.content', 'variant')) RLIKE '^(OBJECT|ARRAY)' THEN NULL
                    ELSE try_variant_get(p, '$.content', 'string') END, ''))), a -> a IS NOT NULL)), char(10)),
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
  CAST(turn_ts AS STRING) AS ts,
  CAST(max(ts) AS STRING) AS ended_at,
  substr(max(CASE WHEN is_start AND ts = turn_ts THEN prompt_text END), 1, 4000) AS prompt,
  substr(max_by(response_text, CASE WHEN response_text IS NOT NULL THEN ts END), 1, 2000) AS response,
  array_join(array_sort(array_distinct(collect_list(
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
