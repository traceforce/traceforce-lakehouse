-- Snowflake SQL version of ../timeline.sql: one session's prompts, tool calls and flagged replies.
-- The message arrays are parsed to give Athena's text (case by case: tests/dashboards/compare_on_fixture.mjs).
-- Trino turns an unpaired UTF-16 surrogate escape into '?'; Snowflake's parser rejects the text, or drops a
-- high half just before a valid pair, so such escapes become '?' before parsing. Escaped backslashes are set aside as CHR(1) first, so
-- \\ud83d stays literal text, and a valid pair is kept as CHR(2)/CHR(3) markers. Text holding a raw CHR(1),
-- CHR(2) or CHR(3) isn't valid JSON for Trino either: it counts as unparseable. 'd' keeps the last of
-- duplicate keys, as Trino does. A part's content that is an object or array counts as no text, as
-- json_extract_scalar does. Known differences, in values agents' JSON doesn't hold: a number written as 1e2
-- or -0.0 reads 100 or 0 (Trino: 100.0, -0.0), and a bare NaN parses (Trino rejects the text).
-- attrs_json values read as json_extract_scalar does: NULL for an object or array. The [PI_DETECTED ...] regex
-- is POSIX: []] in a bracket expression is a literal ], so [^]]* is Java's [^\]]*.
WITH e AS (
  SELECT
    ev."ts", ev."event_name", ev."signal", ev."operation", ev."tool_call_id", ev."tool_name", ev."mcp_server_name",
    ev."tool_args", ev."decision", ev."error_type", ev."prompt_id", ev."generation_id", ev."content_input", ev."content_output",
    TRY_PARSE_JSON(ev."attrs_json") AS "attrs",
    LOWER(REPLACE(ev."agent", 'AGENT_IDENTITY_', '')) AS "agent"
  FROM "agent_events" ev
  WHERE ev."session_id" = {{session_id}}
    AND ev."ts" BETWEEN {{since}} AND {{until}}
    AND ({{person}} IS NULL OR ev."user_email" IS NULL OR LOWER(ev."user_email") = {{person}})
),
a AS (
  SELECT e.*, IFF(IS_OBJECT(e."attrs":"source") OR IS_ARRAY(e."attrs":"source"), NULL, e."attrs":"source"::VARCHAR) AS "decision_source",
    IFF(IS_OBJECT(e."attrs":"gen_ai.response.id") OR IS_ARRAY(e."attrs":"gen_ai.response.id"), NULL, e."attrs":"gen_ai.response.id"::VARCHAR) AS "response_id"
  FROM e
),
prompt_rows AS (
  SELECT a."ts", a."content_input", COALESCE(a."prompt_id", a."generation_id") AS "message_id",
    IFF(CONTAINS(a."content_input", CHR(1)) OR CONTAINS(a."content_input", CHR(2)) OR CONTAINS(a."content_input", CHR(3)), NULL,
        TRY_PARSE_JSON(REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REPLACE(a."content_input", $$\\$$, CHR(1)),
          $$\\u([dD][89abAB][0-9a-fA-F]{2})\\u([dD][c-fC-F][0-9a-fA-F]{2})$$, CHR(2) || $$\1$$ || CHR(3) || $$\2$$),
          $$\\u[dD][89a-fA-F][0-9a-fA-F]{2}$$, '?'),
          CHR(2) || $$([0-9a-fA-F]{4})$$ || CHR(3) || $$([0-9a-fA-F]{4})$$, $$\\u\1\\u\2$$), CHR(1), $$\\$$), 'd')) AS "input_json"
  FROM a
  WHERE a."event_name" IN ('user_prompt', 'beforeSubmitPrompt') AND a."content_input" IS NOT NULL
),
prompt_users AS (
  SELECT prompt_rows.*,
    IFF(IS_ARRAY("input_json"), FILTER("input_json", m -> AS_VARCHAR(m:role) = 'user'), NULL) AS "users"
  FROM prompt_rows
),
prompts AS (
  -- DISTINCT: the same prompt can be stored more than once.
  SELECT DISTINCT "ts", 'prompt' AS "kind", CAST(NULL AS VARCHAR) AS "tool", CAST(NULL AS VARCHAR) AS "tool_call_id",
    SUBSTR(COALESCE(
      -- Text of the last user message; unparseable content is shown raw.
      IFF(IS_ARRAY(GET("users", ARRAY_SIZE("users") - 1):parts),
        ARRAY_TO_STRING(TRANSFORM(GET("users", ARRAY_SIZE("users") - 1):parts, p -> COALESCE(IFF(IS_OBJECT(p:content) OR IS_ARRAY(p:content), NULL, p:content::VARCHAR), '')), CHR(10)), NULL),
      "content_input"), 1, 2000) AS "text",
    CAST(NULL AS VARCHAR) AS "decision", CAST(NULL AS VARCHAR) AS "decision_source", CAST(NULL AS VARCHAR) AS "error_type",
    "message_id"
  FROM prompt_users
),
calls AS (
  -- A call is 1-3 rows sharing tool_call_id (decision, result, span); take the most specific of each field.
  -- Arguments: the best row's, ranked by a leading digit that is then cut (Claude Code's decision row holds only
  -- a placeholder for an MCP call, its result row the real arguments).
  SELECT MIN("ts") AS "ts", 'tool' AS "kind",
    CASE WHEN MAX("mcp_server_name") IS NOT NULL
      THEN MAX("mcp_server_name") || '/' || COALESCE(MAX(CASE WHEN "tool_name" <> 'mcp_tool' THEN "tool_name" END), MAX("tool_name"))
      ELSE COALESCE(MAX(CASE WHEN "tool_name" <> 'mcp_tool' THEN "tool_name" END), MAX("tool_name"), 'tool') END AS "tool",
    "tool_call_id", SUBSTR(SUBSTR(MAX(CASE WHEN "tool_args" IS NOT NULL THEN CONCAT(CASE WHEN "event_name" = 'tool_result' THEN '9' WHEN "event_name" = 'tool_call' THEN '8'
      WHEN "event_name" IN ('postToolUse', 'postToolUseFailure') THEN '7' WHEN "event_name" = 'afterMCPExecution' THEN '6'
      WHEN "event_name" = 'preToolUse' THEN '5' WHEN "signal" = 'span' THEN '4' WHEN "event_name" = 'tool_decision' THEN '1' ELSE '2' END, "tool_args") END), 2), 1, 2000) AS "text",
    MAX("decision") AS "decision", MAX("decision_source") AS "decision_source", MAX("error_type") AS "error_type",
    CAST(NULL AS VARCHAR) AS "message_id"
  FROM a
  WHERE "tool_call_id" IS NOT NULL AND ("operation" = 'execute_tool' OR "event_name" IN
    ('tool_decision', 'tool_result', 'preToolUse', 'postToolUse', 'postToolUseFailure'))
  GROUP BY "tool_call_id"
  UNION ALL
  -- Id-less tool spans (Copilot, Cursor MCP): one row, one call.
  SELECT "ts", 'tool' AS "kind",
    COALESCE(CASE WHEN "mcp_server_name" IS NOT NULL THEN "mcp_server_name" || '/' END, '') || COALESCE("tool_name", 'tool') AS "tool",
    CAST(NULL AS VARCHAR) AS "tool_call_id", SUBSTR("tool_args", 1, 2000) AS "text", "decision", "decision_source", "error_type",
    CAST(NULL AS VARCHAR) AS "message_id"
  FROM a
  WHERE "tool_call_id" IS NULL AND "operation" = 'execute_tool' AND "signal" = 'span'
),
flags AS (
  -- Replies that carry the agent's prompt-injection flag: its leading [PI_DETECTED ...] line(s).
  SELECT DISTINCT "ts", 'reply' AS "kind", CAST(NULL AS VARCHAR) AS "tool", CAST(NULL AS VARCHAR) AS "tool_call_id",
    SUBSTR(REGEXP_SUBSTR("content_output", $$\[PI_DETECTED[^]]*\]$$), 1, 2000) AS "text",
    CAST(NULL AS VARCHAR) AS "decision", CAST(NULL AS VARCHAR) AS "decision_source", CAST(NULL AS VARCHAR) AS "error_type",
    "response_id" AS "message_id"
  FROM a
  WHERE "content_output" LIKE '%[PI_DETECTED%'
)
SELECT TO_CHAR(u."ts", 'YYYY-MM-DD HH24:MI:SS.FF6') AS "ts", u."kind", u."tool", u."tool_call_id", u."text", u."decision",
  u."decision_source", u."error_type", u."message_id"
FROM (SELECT * FROM prompts UNION ALL SELECT * FROM calls UNION ALL SELECT * FROM flags) u
ORDER BY 1
LIMIT 500
