-- Databricks SQL version of ../prompts.sql: one row per prompt (turn) in one session.
-- The message arrays are read as VARIANT, as close to Trino's try(json_parse ...) as Databricks allows:
-- an unpaired UTF-16 surrogate escape (half an emoji) would make the whole text unparseable, so it is
-- retried with only the unpaired escapes as U+FFFD (whole emoji kept; escaped backslashes are set
-- aside as U+0001 first, so \\ud83d stays literal text; text that already holds a raw U+0001, invalid
-- JSON, isn't retried); a
-- part's content that is an object or array counts as no text, as json_extract_scalar does; a message
-- without parts is skipped; try_element_at gives NULL for an empty array.
WITH ev AS (
  SELECT
    lower(replace(e.agent, 'AGENT_IDENTITY_', '')) AS agent,
    coalesce(lower(e.user_email), lower(m.owner_email)) AS person,
    e.session_id, e.ts, e.event_name, e.signal, e.operation, e.model, e.tool_call_id,
    e.input_tokens, e.output_tokens, e.cost_usd, e.content_input, e.content_output
  FROM traceforce_lakehouse.traceforce.agent_events e
  LEFT JOIN traceforce_lakehouse.traceforce.device_owner_mappings m ON m.device_native_id = e.device_native_id
  WHERE e.ts >= CAST({{since}} AS TIMESTAMP_NTZ) AND e.session_id = {{session_id}}
    AND lower(replace(e.agent, 'AGENT_IDENTITY_', '')) = {{agent}}
    AND coalesce(lower(e.user_email), lower(m.owner_email)) IS NOT DISTINCT FROM {{person}}
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
