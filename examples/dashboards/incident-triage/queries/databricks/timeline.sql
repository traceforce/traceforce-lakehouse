-- Databricks SQL version of ../timeline.sql: what happened in one session around its findings.
-- {{since}} and {{until}} are UTC: the runner must write them as TIMESTAMP_NTZ '...'. A TIMESTAMP '...' literal is
-- read in the session's time zone and moves an hour inside a daylight-saving gap.
-- Message text as in ../../../usage-and-spend/queries/databricks/prompts.sql (read as VARIANT; see there).
WITH e AS (
  SELECT
    ev.ts, ev.event_name, ev.signal, ev.operation, ev.tool_call_id, ev.tool_name, ev.mcp_server_name,
    ev.tool_args, ev.decision, ev.error_type, ev.prompt_id, ev.generation_id, ev.content_input, ev.content_output,
    get_json_object(ev.attrs_json, '$.source') AS decision_source,
    get_json_object(ev.attrs_json, '$["gen_ai.response.id"]') AS response_id,
    lower(replace(ev.agent, 'AGENT_IDENTITY_', '')) AS agent
  FROM traceforce_lakehouse.traceforce.agent_events ev
  WHERE ev.session_id = {{session_id}}
    AND ev.ts BETWEEN CAST({{since}} AS TIMESTAMP_NTZ) AND CAST({{until}} AS TIMESTAMP_NTZ)
    AND ({{person}} IS NULL OR ev.user_email IS NULL OR lower(ev.user_email) = {{person}})
),
prompts AS (
  SELECT DISTINCT ts, 'prompt' AS kind, CAST(NULL AS STRING) AS tool, CAST(NULL AS STRING) AS tool_call_id,
    substr(coalesce(
      array_join(transform(
        try_variant_get(
          try_element_at(filter(try_variant_get(coalesce(try_parse_json(content_input), CASE WHEN instr(content_input, char(1)) = 0 THEN try_parse_json(replace(regexp_replace(regexp_replace(replace(content_input, concat(char(92), char(92)), char(1)), r'\\u[dD][89abAB][0-9a-fA-F]{2}(?!\\u[dD][c-fC-F][0-9a-fA-F]{2})', r'\\ufffd'), r'(?<!\\u[dD][89abAB][0-9a-fA-F]{2})\\u[dD][c-fC-F][0-9a-fA-F]{2}', r'\\ufffd'), char(1), concat(char(92), char(92)))) END), '$', 'array<variant>'),
                                x -> try_variant_get(x, '$.role', 'string') = 'user'), -1),
          '$.parts', 'array<variant>'),
        p -> coalesce(CASE WHEN schema_of_variant(try_variant_get(p, '$.content', 'variant')) RLIKE '^(OBJECT|ARRAY)' THEN NULL
                    ELSE try_variant_get(p, '$.content', 'string') END, '')), char(10)),
      content_input), 1, 2000) AS text,
    CAST(NULL AS STRING) AS decision, CAST(NULL AS STRING) AS decision_source, CAST(NULL AS STRING) AS error_type,
    coalesce(prompt_id, generation_id) AS message_id
  FROM e
  WHERE event_name IN ('user_prompt', 'beforeSubmitPrompt') AND content_input IS NOT NULL
),
calls AS (
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
  SELECT ts, 'tool', coalesce(CASE WHEN mcp_server_name IS NOT NULL THEN mcp_server_name || '/' END, '') || coalesce(tool_name, 'tool'),
    NULL, substr(tool_args, 1, 2000), decision, decision_source, error_type, NULL
  FROM e
  WHERE tool_call_id IS NULL AND operation = 'execute_tool' AND signal = 'span'
),
flags AS (
  -- Replies that carry the agent's prompt-injection flag: its leading [PI_DETECTED ...] line(s).
  SELECT DISTINCT ts, 'reply', NULL, NULL,
    substr(nullif(regexp_extract(content_output, r'\[PI_DETECTED[^\]]*\]', 0), ''), 1, 2000),
    NULL, NULL, NULL, response_id
  FROM e
  WHERE content_output LIKE '%[PI_DETECTED%'
)
SELECT CAST(ts AS STRING) AS ts, kind, tool, tool_call_id, text, decision, decision_source, error_type, message_id
FROM (SELECT * FROM prompts UNION ALL SELECT * FROM calls UNION ALL SELECT * FROM flags)
ORDER BY ts
LIMIT 500
