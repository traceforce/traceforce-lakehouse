-- Snowflake SQL version of ../unattributed.sql: activity with no person, per (UTC day, agent, device serial).
WITH src AS (
  SELECT ev."ts"::DATE AS "day", LOWER(REPLACE(ev."agent", 'AGENT_IDENTITY_', '')) AS "agent",
         COALESCE(ev."device_native_id", 'unknown') AS "device_native_id",
         ev."ts" AS "ts", ev."session_id" AS "session_id", ev."tool_call_id" AS "tool_call_id", ev."signal" AS "signal",
         ev."operation" AS "operation", ev."input_tokens" AS "input_tokens", ev."output_tokens" AS "output_tokens",
         ev."cost_usd" AS "cost_usd",
         ev."prompt_id" AS "prompt_id", ev."generation_id" AS "generation_id", ev."event_name" AS "event_name",
         ev."tool_name" AS "tool_name", ev."mcp_server_name" AS "mcp_server_name",
         REGEXP_REPLACE(COALESCE(ev."mcp_server_name", ''), '[^A-Za-z0-9_-]', '_') AS "server_key"
  FROM "agent_events" ev
  LEFT JOIN "device_owner_mappings" m ON m."device_native_id" = ev."device_native_id"
  WHERE ev."ts" >= DATEADD('day', -90, CURRENT_DATE())::TIMESTAMP_NTZ
    AND ev."user_email" IS NULL AND m."owner_email" IS NULL
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
e AS (
  SELECT * FROM (
    SELECT flagged.*,
      -- ts only splits the id-less rows, whose value is unused, into small partitions.
      MAX(CASE WHEN "app_call" THEN 1 ELSE 0 END)
        OVER (PARTITION BY "tool_call_id", "operation", CASE WHEN "tool_call_id" IS NULL THEN "ts" END) AS "call_app_call"
    FROM flagged
  ) f
  WHERE NOT "app_call" AND ("tool_call_id" IS NULL OR "call_app_call" = 0)
),
usage AS (
  SELECT "day", "agent", "device_native_id",
         COUNT(DISTINCT CASE WHEN "operation" = 'execute_tool' THEN "tool_call_id" END)
           + COUNT_IF("operation" = 'execute_tool' AND "tool_call_id" IS NULL AND "signal" = 'span') AS "tool_calls",
         SUM(CASE WHEN "operation" IS DISTINCT FROM 'invoke_agent' THEN COALESCE("input_tokens", 0) + COALESCE("output_tokens", 0) END) AS "tokens",
         SUM("cost_usd") AS "cost_usd"
  FROM e GROUP BY 1, 2, 3
),
sessions AS (
  SELECT "day", "agent", "device_native_id", COUNT(*) AS "sessions"
  FROM (SELECT MIN("ts")::DATE AS "day", "agent", "device_native_id", "session_id"
        FROM e WHERE "session_id" IS NOT NULL GROUP BY 2, 3, 4
        -- Hide noise sessions: no prompt, tool call, tokens, cost, TraceForce block or failed tool attempt (only startup, hook or connection events).
        HAVING (COUNT(COALESCE("prompt_id", "generation_id")) > 0
          OR COUNT_IF("event_name" IN ('user_prompt', 'beforeSubmitPrompt', 'traceforce.enforcement', 'postToolUseFailure') OR ("signal" = 'span' AND "operation" = 'chat')) > 0
          OR COUNT(DISTINCT CASE WHEN "operation" = 'execute_tool' THEN "tool_call_id" END)
            + COUNT_IF("operation" = 'execute_tool' AND "tool_call_id" IS NULL AND "signal" = 'span') > 0
          OR COALESCE(SUM(e."cost_usd"), 0) <> 0
          OR COALESCE(SUM(CASE WHEN "operation" IS DISTINCT FROM 'invoke_agent' THEN COALESCE(e."input_tokens", 0) + COALESCE(e."output_tokens", 0) END), 0) <> 0))
  GROUP BY 1, 2, 3
)
SELECT TO_CHAR(COALESCE(u."day", s."day"), 'YYYY-MM-DD') AS "day", COALESCE(u."agent", s."agent") AS "agent",
       COALESCE(u."device_native_id", s."device_native_id") AS "device_native_id",
       COALESCE(s."sessions", 0) AS "sessions", COALESCE(u."tool_calls", 0) AS "tool_calls",
       u."tokens" AS "tokens", u."cost_usd" AS "cost_usd"
FROM usage u
FULL OUTER JOIN sessions s ON s."day" = u."day" AND s."agent" = u."agent" AND s."device_native_id" = u."device_native_id"
-- Rows left all zero (only hidden sessions) would show people and devices with no activity.
WHERE COALESCE(s."sessions", 0) + COALESCE(u."tool_calls", 0) > 0
  OR COALESCE(u."tokens", 0) <> 0
  OR COALESCE(u."cost_usd", 0) <> 0
ORDER BY 1, 2, 3
