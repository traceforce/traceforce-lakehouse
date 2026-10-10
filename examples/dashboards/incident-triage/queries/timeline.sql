-- What happened in one session around its findings, for the incident drill-down: the prompts, the tool calls
-- (with the command or arguments, and who approved or denied them) and the replies that flagged a prompt
-- injection. serve.mjs fills in the session id, the person (NULL when unknown), and a time window around
-- the findings. The page attaches each finding to its row by tool_call_id or message id.
-- The same session id can exist under two accounts, so rows carrying another person's email are left out.
WITH e AS (
  SELECT
    ev.ts, ev.event_name, ev.signal, ev.operation, ev.tool_call_id, ev.tool_name, ev.mcp_server_name,
    ev.tool_args, ev.decision, ev.error_type, ev.prompt_id, ev.generation_id, ev.content_input, ev.content_output,
    json_extract_scalar(ev.attrs_json, '$.source') AS decision_source,
    json_extract_scalar(ev.attrs_json, '$["gen_ai.response.id"]') AS response_id,
    lower(replace(ev.agent, 'AGENT_IDENTITY_', '')) AS agent
  FROM agent_events ev
  WHERE ev.session_id = {{session_id}}
    AND ev.ts BETWEEN {{since}} AND {{until}}
    AND ({{person}} IS NULL OR ev.user_email IS NULL OR lower(ev.user_email) = {{person}})
),
prompts AS (
  SELECT ts, 'prompt' AS kind, NULL AS tool, NULL AS tool_call_id,
    substr(coalesce(
      -- Text of the last user message in the JSON message array; unparseable content is shown raw.
      try(array_join(transform(
        cast(json_extract(element_at(filter(cast(json_parse(content_input) AS array(json)),
               x -> json_extract_scalar(x, '$.role') = 'user'), -1), '$.parts') AS array(json)),
        p -> coalesce(json_extract_scalar(p, '$.content'), '')), chr(10))),
      content_input), 1, 2000) AS text,
    NULL AS decision, NULL AS decision_source, NULL AS error_type,
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
    NULL AS message_id
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
    substr(regexp_extract(content_output, '\[PI_DETECTED[^\]]*\]'), 1, 2000),
    NULL, NULL, NULL, response_id
  FROM e
  WHERE content_output LIKE '%[PI_DETECTED%'
)
SELECT cast(ts AS varchar) AS ts, kind, tool, tool_call_id, text, decision, decision_source, error_type, message_id
FROM (SELECT * FROM prompts UNION ALL SELECT * FROM calls UNION ALL SELECT * FROM flags)
ORDER BY ts
LIMIT 500
