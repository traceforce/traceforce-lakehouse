-- Snowflake SQL version of ../sessions.sql: one person's sessions in the last 90 days.
-- MIN(device_native_id) where Databricks has any_value(..., true): Snowflake's ANY_VALUE may pick a NULL.
WITH src AS (
  SELECT
    LOWER(REPLACE(ev."agent", 'AGENT_IDENTITY_', '')) AS "agent",
    COALESCE(LOWER(ev."user_email"), LOWER(m."owner_email")) AS "person",
    ev."session_id" AS "session_id", ev."device_native_id" AS "device_native_id", ev."ts" AS "ts",
    CASE WHEN (ev."input_tokens" IS NOT NULL OR ev."cost_usd" IS NOT NULL) AND ev."operation" IS DISTINCT FROM 'invoke_agent'
      THEN ev."model" END AS "priced_model",
    ev."prompt_id" AS "prompt_id", ev."generation_id" AS "generation_id", ev."tool_call_id" AS "tool_call_id",
    ev."signal" AS "signal", ev."operation" AS "operation", ev."input_tokens" AS "input_tokens",
    ev."output_tokens" AS "output_tokens", ev."cost_usd" AS "cost_usd",
    ev."tool_name" AS "tool_name", ev."mcp_server_name" AS "mcp_server_name",
    REGEXP_REPLACE(COALESCE(ev."mcp_server_name", ''), '[^A-Za-z0-9_-]', '_') AS "server_key"
  FROM "agent_events" ev
  LEFT JOIN "device_owner_mappings" m ON m."device_native_id" = ev."device_native_id"
  WHERE ev."ts" >= DATEADD('day', -91, CURRENT_DATE())::TIMESTAMP_NTZ
    AND ev."session_id" IS NOT NULL
    AND COALESCE(LOWER(ev."user_email"), LOWER(m."owner_email")) IS NOT DISTINCT FROM {{person}}
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
-- Per call: Claude Code's decision and result rows say 'mcp_tool' and only its span names the tool.
e AS (
  SELECT f.* FROM flagged f
  LEFT JOIN (SELECT DISTINCT "tool_call_id" FROM flagged WHERE "app_call") a
    ON a."tool_call_id" = f."tool_call_id" AND f."operation" = 'execute_tool'
  WHERE NOT f."app_call" AND a."tool_call_id" IS NULL
)
SELECT
  "agent", "person", "session_id",
  MIN("device_native_id") AS "device_native_id",
  TO_CHAR(MIN("ts"), 'YYYY-MM-DD HH24:MI:SS.FF6') AS "started_at",
  TO_CHAR(MAX("ts"), 'YYYY-MM-DD HH24:MI:SS.FF6') AS "ended_at",
  LISTAGG(DISTINCT "priced_model", ', ') WITHIN GROUP (ORDER BY "priced_model") AS "models",
  COUNT(DISTINCT COALESCE("prompt_id", "generation_id")) AS "prompts",
  COUNT(DISTINCT CASE WHEN "operation" = 'execute_tool' THEN "tool_call_id" END)
    + COUNT_IF("operation" = 'execute_tool' AND "tool_call_id" IS NULL AND "signal" = 'span') AS "tool_calls",
  SUM(CASE WHEN "operation" IS DISTINCT FROM 'invoke_agent' THEN "input_tokens" END) AS "input_tokens",
  SUM(CASE WHEN "operation" IS DISTINCT FROM 'invoke_agent' THEN "output_tokens" END) AS "output_tokens",
  SUM("cost_usd") AS "cost_usd"
FROM e
GROUP BY 1, 2, 3
HAVING MIN("ts") >= DATEADD('day', -90, CURRENT_DATE())::TIMESTAMP_NTZ
ORDER BY "started_at"
