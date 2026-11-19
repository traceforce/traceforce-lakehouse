-- Snowflake SQL version of ../prompts.sql: one row per prompt (turn) in one session.
-- The message arrays are parsed to give Athena's text (case by case: tests/dashboards/compare_on_fixture.mjs).
-- Trino turns an unpaired UTF-16 surrogate escape into '?'; Snowflake's parser rejects the text, or drops a
-- high half just before a valid pair, so such escapes become '?' before parsing. Escaped backslashes are set aside as CHR(1) first, so
-- \\ud83d stays literal text, and a valid pair is kept as CHR(2)/CHR(3) markers. Text holding a raw CHR(1),
-- CHR(2) or CHR(3) isn't valid JSON for Trino either: it counts as unparseable. 'd' keeps the last of
-- duplicate keys, as Trino does. A part's content that is an object or array counts as no text, as
-- json_extract_scalar does. Known differences, in values agents' JSON doesn't hold: a number written as 1e2
-- or -0.0 reads 100 or 0 (Trino: 100.0, -0.0), and a bare NaN parses (Trino rejects the text).
WITH src AS (
  SELECT
    LOWER(REPLACE(e."agent", 'AGENT_IDENTITY_', '')) AS "agent",
    COALESCE(LOWER(e."user_email"), LOWER(m."owner_email")) AS "person",
    e."session_id", e."ts", e."event_name", e."signal", e."operation", e."tool_call_id",
    CASE WHEN (e."input_tokens" IS NOT NULL OR e."cost_usd" IS NOT NULL) AND e."operation" IS DISTINCT FROM 'invoke_agent'
      THEN e."model" END AS "priced_model",
    e."input_tokens", e."output_tokens", e."cost_usd", e."content_input", e."content_output",
    -- Prompt rows: the agents' prompt events, and Copilot's chat spans (its only carrier of prompt text).
    e."content_input" IS NOT NULL AND (e."event_name" IN ('user_prompt', 'beforeSubmitPrompt')
      OR (e."signal" = 'span' AND e."operation" = 'chat')) AS "is_prompt",
    e."content_output" IS NOT NULL AND (e."event_name" IN ('assistant_response', 'afterAgentResponse', 'agent_response')
      OR (e."signal" = 'span' AND e."operation" = 'chat')) AS "is_response",
    e."tool_name", e."mcp_server_name",
    REGEXP_REPLACE(COALESCE(e."mcp_server_name", ''), '[^A-Za-z0-9_-]', '_') AS "server_key"
  FROM "agent_events" e
  LEFT JOIN "device_owner_mappings" m ON m."device_native_id" = e."device_native_id"
  WHERE e."ts" >= {{since}} AND e."session_id" = {{session_id}}
    AND LOWER(REPLACE(e."agent", 'AGENT_IDENTITY_', '')) = {{agent}}
    AND COALESCE(LOWER(e."user_email"), LOWER(m."owner_email")) IS NOT DISTINCT FROM {{person}}
),
-- The agent app's calls that drive the app itself, not the person's work: scout's hostappmcp.IsHostAppMCP
-- (server_key spells the server as its mcpServerKey does), plus built-in plumbing. Keep the two in step.
flagged AS (
  SELECT src.*, COALESCE("operation" = 'execute_tool' AND (
    ("agent" IN ('claude', 'claude_code') AND (
      SUBSTR("server_key", 1, 4) = 'ccd_'
      OR "server_key" IN ('cowork', 'scheduled-tasks', 'hearthbot', 'claude-code-remote', 'Claude_Code_Remote',
                          'claude_ai_Claude_Docs', '1a59c906-04da-521d-bda7-7f71b9f9e01c', 'visualize')
      OR ("server_key" IN ('Claude_Browser', 'Claude_Preview') AND "tool_name" IN ('preview_start', 'preview_stop', 'preview_list', 'preview_logs'))
      OR ("server_key" = 'terminal' AND "tool_name" IN ('read_terminal', 'open_terminal_tab', 'list_terminal_tabs', 'stop_terminal_tab'))
      OR ("server_key" = 'memory' AND "tool_name" IN ('memory_read', 'memory_list', 'memory_write', 'memory_str_replace', 'memory_append', 'memory_delete'))))
    OR ("agent" = 'chatgpt_codex' AND (
      REPLACE("server_key", '-', '_') IN ('codex_app', 'codex_security')
      OR (REPLACE("server_key", '-', '_') IN ('node_repl', 'cua_repl') AND "tool_name" IN ('js_reset', 'js_add_node_module_dir'))
      OR (REPLACE("server_key", '-', '_') = 'codex_apps' AND REGEXP_REPLACE(REGEXP_REPLACE("tool_name", '^.*__', ''), '^_+', '')
          IN ('web_run', 'write_page_reference', 'create_plugin', 'update_app_permissions', 'save_site_version', 'create_source_repository_write_credential'))))
    OR ("agent" = 'cursor' AND (("server_key" = '' AND "tool_name" IN ('move_agent_to_root', 'move_agent_to_cloned_root'))
      OR "server_key" IN ('cursor-app-control', 'cursor-backend-control', 'cursor-subscriptions')))
    -- Built-in plumbing with no server: tool search, structured output, subagent handback, Claude's compose and present.
    OR ("server_key" = '' AND "tool_name" IN ('ToolSearch', 'StructuredOutput', 'SubagentHandback', 'tool_search', 'tool_search_tool', 'message_compose_v1', 'present_files'))), FALSE) AS "app_call"
  FROM src
),
-- Per call: Claude Code's decision and result rows say 'mcp_tool' and only its span names the tool, so a call
-- goes whole when any of its rows is the app's. An id-less row (a Copilot span) goes on its own flag.
ev AS (
  SELECT * FROM (
    SELECT flagged.*,
      -- ts only splits the id-less rows, whose value is unused, into small partitions.
      MAX(CASE WHEN "app_call" THEN 1 ELSE 0 END)
        OVER (PARTITION BY "tool_call_id", "operation", CASE WHEN "tool_call_id" IS NULL THEN "ts" END) AS "call_app_call"
    FROM flagged
  ) f
  WHERE NOT "app_call" AND ("tool_call_id" IS NULL OR "call_app_call" = 0)
),
parsed AS (
  SELECT ev.*,
    IFF("is_prompt", IFF(CONTAINS(ev."content_input", CHR(1)) OR CONTAINS(ev."content_input", CHR(2)) OR CONTAINS(ev."content_input", CHR(3)), NULL,
        TRY_PARSE_JSON(REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REPLACE(ev."content_input", $$\\$$, CHR(1)),
          $$\\u([dD][89abAB][0-9a-fA-F]{2})\\u([dD][c-fC-F][0-9a-fA-F]{2})$$, CHR(2) || $$\1$$ || CHR(3) || $$\2$$),
          $$\\u[dD][89a-fA-F][0-9a-fA-F]{2}$$, '?'),
          CHR(2) || $$([0-9a-fA-F]{4})$$ || CHR(3) || $$([0-9a-fA-F]{4})$$, $$\\u\1\\u\2$$), CHR(1), $$\\$$), 'd')), NULL) AS "input_json",
    IFF("is_response", IFF(CONTAINS(ev."content_output", CHR(1)) OR CONTAINS(ev."content_output", CHR(2)) OR CONTAINS(ev."content_output", CHR(3)), NULL,
        TRY_PARSE_JSON(REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REPLACE(ev."content_output", $$\\$$, CHR(1)),
          $$\\u([dD][89abAB][0-9a-fA-F]{2})\\u([dD][c-fC-F][0-9a-fA-F]{2})$$, CHR(2) || $$\1$$ || CHR(3) || $$\2$$),
          $$\\u[dD][89a-fA-F][0-9a-fA-F]{2}$$, '?'),
          CHR(2) || $$([0-9a-fA-F]{4})$$ || CHR(3) || $$([0-9a-fA-F]{4})$$, $$\\u\1\\u\2$$), CHR(1), $$\\$$), 'd')), NULL) AS "output_json"
  FROM ev
),
msgs AS (
  SELECT parsed.*,
    IFF(IS_ARRAY("input_json"), FILTER("input_json", m -> AS_VARCHAR(m:role) = 'user'), NULL) AS "users",
    IFF(IS_ARRAY("output_json"), FILTER("output_json", m -> AS_VARCHAR(m:role) = 'assistant'), NULL) AS "assistants"
  FROM parsed
),
txt AS (
  SELECT msgs.*,
    CASE WHEN "is_prompt" THEN COALESCE(
      -- Text of the last user message, its parts joined by newlines; no user message or parts: NULL.
      IFF(IS_ARRAY(GET("users", ARRAY_SIZE("users") - 1):parts),
        ARRAY_TO_STRING(TRANSFORM(GET("users", ARRAY_SIZE("users") - 1):parts, p -> COALESCE(IFF(IS_OBJECT(p:content) OR IS_ARRAY(p:content), NULL, p:content::VARCHAR), '')), CHR(10)), NULL),
      -- Unparseable log content is shown raw; a Copilot span with no user message continues the current turn.
      CASE WHEN "signal" = 'log' THEN "content_input" END)
    END AS "prompt_text",
    CASE WHEN "is_response" THEN COALESCE(
      -- Every assistant message's parts; one without parts is skipped, but parts that aren't an array make the
      -- whole text unreadable (Trino's cast fails), so the raw content is shown.
      IFF(ARRAY_SIZE(FILTER("assistants", m -> m:parts IS NOT NULL AND NOT IS_NULL_VALUE(m:parts) AND NOT IS_ARRAY(m:parts))) > 0, NULL,
        ARRAY_TO_STRING(ARRAY_FLATTEN(TRANSFORM(FILTER("assistants", m -> IS_ARRAY(m:parts)),
          m -> TRANSFORM(m:parts, p -> COALESCE(IFF(IS_OBJECT(p:content) OR IS_ARRAY(p:content), NULL, p:content::VARCHAR), '')))), CHR(10))),
      "content_output")
    END AS "response_text"
  FROM msgs
),
starts AS (
  SELECT txt.*,
    -- A Copilot tool loop repeats the same user message on every chat span: only a changed message starts a turn.
    "prompt_text" IS NOT NULL AND ("signal" = 'log' OR "prompt_text" IS DISTINCT FROM
      LAG("prompt_text") OVER (PARTITION BY "agent", "person", "session_id", "prompt_text" IS NOT NULL ORDER BY "ts")) AS "is_start"
  FROM txt
),
turns AS (
  SELECT starts.*,
    MAX(CASE WHEN "is_start" THEN "ts" END) OVER (PARTITION BY "agent", "person", "session_id" ORDER BY "ts"
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "turn_ts"
  FROM starts
)
SELECT
  "agent", "person", "session_id",
  TO_CHAR("turn_ts", 'YYYY-MM-DD HH24:MI:SS.FF6') AS "ts",
  TO_CHAR(MAX("ts"), 'YYYY-MM-DD HH24:MI:SS.FF6') AS "ended_at",
  SUBSTR(MAX(CASE WHEN "is_start" AND "ts" = "turn_ts" THEN "prompt_text" END), 1, 4000) AS "prompt",
  SUBSTR(MAX_BY("response_text", CASE WHEN "response_text" IS NOT NULL THEN "ts" END), 1, 2000) AS "response",
  LISTAGG(DISTINCT "priced_model", ', ') WITHIN GROUP (ORDER BY "priced_model") AS "models",
  COUNT(DISTINCT CASE WHEN "operation" = 'execute_tool' THEN "tool_call_id" END)
    + COUNT_IF("operation" = 'execute_tool' AND "tool_call_id" IS NULL AND "signal" = 'span') AS "tool_calls",
  SUM(CASE WHEN "operation" IS DISTINCT FROM 'invoke_agent' THEN "input_tokens" END) AS "input_tokens",
  SUM(CASE WHEN "operation" IS DISTINCT FROM 'invoke_agent' THEN "output_tokens" END) AS "output_tokens",
  SUM("cost_usd") AS "cost_usd"
FROM turns
WHERE "turn_ts" IS NOT NULL
GROUP BY 1, 2, 3, "turn_ts"
ORDER BY 3, 4
