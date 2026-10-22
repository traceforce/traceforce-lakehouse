-- BigQuery (GoogleSQL) version of ../timeline.sql: what happened in one session around its findings.
WITH e AS (
  SELECT
    ev.ts, ev.event_name, ev.signal, ev.operation, ev.tool_call_id, ev.tool_name, ev.mcp_server_name,
    ev.tool_args, ev.decision, ev.error_type, ev.prompt_id, ev.generation_id, ev.content_input, ev.content_output,
    JSON_VALUE(ev.attrs_json, '$.source') AS decision_source,
    JSON_VALUE(ev.attrs_json, '$."gen_ai.response.id"') AS response_id,
    lower(replace(ev.agent, 'AGENT_IDENTITY_', '')) AS agent
  FROM traceforce_lakehouse.agent_events ev
  WHERE ev.session_id = {{session_id}}
    AND ev.ts BETWEEN {{since}} AND {{until}}
    AND ({{person}} IS NULL OR ev.user_email IS NULL OR lower(ev.user_email) = {{person}})
),
prompts AS (
  SELECT ts, 'prompt' AS kind, CAST(NULL AS STRING) AS tool, CAST(NULL AS STRING) AS tool_call_id,
    substr(coalesce(
      -- Text of the last user message in the JSON message array; unparseable content is shown raw.
      (SELECT STRING_AGG(coalesce(JSON_VALUE(p, '$.content'), ''), '\n' ORDER BY o)
       FROM UNNEST(JSON_QUERY_ARRAY(
         (SELECT x FROM UNNEST(JSON_QUERY_ARRAY(SAFE.PARSE_JSON(content_input))) x WITH OFFSET i
          WHERE JSON_VALUE(x, '$.role') = 'user' ORDER BY i DESC LIMIT 1), '$.parts')) p WITH OFFSET o),
      content_input), 1, 2000) AS text,
    CAST(NULL AS STRING) AS decision, CAST(NULL AS STRING) AS decision_source, CAST(NULL AS STRING) AS error_type,
    coalesce(prompt_id, generation_id) AS message_id
  FROM e
  WHERE event_name IN ('user_prompt', 'beforeSubmitPrompt') AND content_input IS NOT NULL
),
calls AS (
  -- A call is 1-3 rows sharing tool_call_id (decision, result, span); take the most specific of each field.
  SELECT min(ts) AS ts, 'tool' AS kind,
    CASE WHEN max(mcp_server_name) IS NOT NULL
      THEN max(mcp_server_name) || '/' || coalesce(max(CASE WHEN tool_name <> 'mcp_tool' THEN tool_name END), max(tool_name))
      ELSE coalesce(max(CASE WHEN tool_name <> 'mcp_tool' THEN tool_name END), max(tool_name), 'tool') END AS tool,
    tool_call_id, substr(max(tool_args), 1, 2000) AS text,
    max(decision) AS decision, max(decision_source) AS decision_source, max(error_type) AS error_type,
    CAST(NULL AS STRING) AS message_id
  FROM e
  WHERE tool_call_id IS NOT NULL AND (operation = 'execute_tool' OR event_name IN
    ('tool_decision', 'tool_result', 'preToolUse', 'postToolUse', 'postToolUseFailure'))
  GROUP BY tool_call_id
  UNION ALL
  -- Id-less tool spans (Copilot, Cursor MCP): one row, one call.
  SELECT ts, 'tool', coalesce(CASE WHEN mcp_server_name IS NOT NULL THEN mcp_server_name || '/' END, '') || coalesce(tool_name, 'tool'),
    NULL, substr(tool_args, 1, 2000), decision, decision_source, error_type, NULL
  FROM e
  WHERE tool_call_id IS NULL AND operation = 'execute_tool' AND signal = 'span'
),
flags AS (
  -- Replies that carry the agent's prompt-injection flag: its leading [PI_DETECTED ...] line(s).
  SELECT ts, 'reply', NULL, NULL,
    substr(REGEXP_EXTRACT(content_output, r'\[PI_DETECTED[^\]]*\]'), 1, 2000),
    NULL, NULL, NULL, response_id
  FROM e
  WHERE content_output LIKE '%[PI_DETECTED%'
)
SELECT FORMAT_TIMESTAMP('%F %H:%M:%E6S', u.ts) AS ts, kind, tool, tool_call_id, text, decision, decision_source, error_type, message_id
FROM (SELECT * FROM prompts UNION ALL SELECT * FROM calls UNION ALL SELECT * FROM flags) u
ORDER BY u.ts
LIMIT 500
