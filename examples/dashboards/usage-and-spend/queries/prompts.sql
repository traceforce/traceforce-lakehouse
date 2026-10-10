-- One row per prompt (turn) in one session, for the session drill-down. serve.py fills in the agent, person
-- (NULL for unattributed), session id and the session's start, which bounds the scan.
-- A turn runs from one user prompt to the next in the same session; every row in between (model calls,
-- tool calls, the response) is credited to it. This works for agents with no prompt id (Codex, Copilot).
-- Prompt and response text are the stored content: masked per the org's redaction policy, truncated here.
WITH ev AS (
  SELECT
    lower(replace(e.agent, 'AGENT_IDENTITY_', '')) AS agent,
    coalesce(lower(e.user_email), lower(m.owner_email)) AS person,
    e.session_id, e.ts, e.event_name, e.signal, e.operation, e.model, e.tool_call_id,
    e.input_tokens, e.output_tokens, e.cost_usd, e.content_input, e.content_output
  FROM agent_events e
  LEFT JOIN device_owner_mappings m ON m.device_native_id = e.device_native_id
  WHERE e.ts >= {{since}} AND e.session_id = {{session_id}}
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
