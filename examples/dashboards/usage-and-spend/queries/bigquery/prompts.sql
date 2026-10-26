-- BigQuery (GoogleSQL) version of ../prompts.sql: one row per prompt (turn) in one session.
-- Also in traceforce-ui src/lib/lakehouse/queries/usage.ts (the in-app GCP dashboards): keep the two in sync.
-- The JSON message arrays are parsed with SAFE.PARSE_JSON, so unparseable content falls back to the raw text.
WITH ev AS (
  SELECT
    lower(replace(e.agent, 'AGENT_IDENTITY_', '')) AS agent,
    coalesce(lower(e.user_email), lower(m.owner_email)) AS person,
    e.session_id, e.ts, e.event_name, e.signal, e.operation, e.model, e.tool_call_id,
    e.input_tokens, e.output_tokens, e.cost_usd, e.content_input, e.content_output
  FROM traceforce_lakehouse.agent_events e
  LEFT JOIN traceforce_lakehouse.device_owner_mappings m ON m.device_native_id = e.device_native_id
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
        (SELECT STRING_AGG(coalesce(JSON_VALUE(p, '$.content'), ''), '\n' ORDER BY o)
         FROM UNNEST(JSON_QUERY_ARRAY(
           (SELECT x FROM UNNEST(JSON_QUERY_ARRAY(SAFE.PARSE_JSON(content_input))) x WITH OFFSET i
            WHERE JSON_VALUE(x, '$.role') = 'user' ORDER BY i DESC LIMIT 1), '$.parts')) p WITH OFFSET o),
        -- Unparseable log content is shown raw; a Copilot span with no user message continues the current turn.
        CASE WHEN signal = 'log' THEN content_input END)
    END AS prompt_text,
    CASE WHEN content_output IS NOT NULL
          AND (event_name IN ('assistant_response', 'afterAgentResponse', 'agent_response') OR (signal = 'span' AND operation = 'chat'))
      THEN coalesce(
        -- Text of every assistant message in the JSON message array.
        (SELECT STRING_AGG(coalesce(JSON_VALUE(p, '$.content'), ''), '\n' ORDER BY i, o)
         FROM UNNEST(JSON_QUERY_ARRAY(SAFE.PARSE_JSON(content_output))) x WITH OFFSET i,
              UNNEST(JSON_QUERY_ARRAY(x, '$.parts')) p WITH OFFSET o
         WHERE JSON_VALUE(x, '$.role') = 'assistant'),
        content_output)
    END AS response_text
  FROM ev
),
starts AS (
  SELECT txt.*,
    -- A Copilot tool loop repeats the same user message on every chat span: only a changed message starts a turn.
    prompt_text IS NOT NULL AND (signal = 'log' OR prompt_text IS DISTINCT FROM
      LAG(prompt_text) OVER (PARTITION BY agent, person, session_id, prompt_text IS NOT NULL ORDER BY ts)) AS is_start
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
  FORMAT_TIMESTAMP('%F %H:%M:%E6S', turn_ts) AS ts,
  FORMAT_TIMESTAMP('%F %H:%M:%E6S', max(ts)) AS ended_at,
  substr(max(CASE WHEN is_start AND ts = turn_ts THEN prompt_text END), 1, 4000) AS prompt,
  substr(ARRAY_AGG(response_text IGNORE NULLS ORDER BY ts DESC LIMIT 1)[SAFE_OFFSET(0)], 1, 2000) AS response,
  STRING_AGG(DISTINCT billed_model, ', ' ORDER BY billed_model) AS models,
  count(DISTINCT CASE WHEN operation = 'execute_tool' THEN tool_call_id END)
    + COUNTIF(operation = 'execute_tool' AND tool_call_id IS NULL AND signal = 'span') AS tool_calls,
  sum(CASE WHEN operation IS DISTINCT FROM 'invoke_agent' THEN input_tokens END) AS input_tokens,
  sum(CASE WHEN operation IS DISTINCT FROM 'invoke_agent' THEN output_tokens END) AS output_tokens,
  sum(cost_usd) AS cost_usd
FROM (
  SELECT turns.*,
    CASE WHEN (input_tokens IS NOT NULL OR cost_usd IS NOT NULL) AND operation IS DISTINCT FROM 'invoke_agent'
      THEN model END AS billed_model
  FROM turns
)
WHERE turn_ts IS NOT NULL
GROUP BY agent, person, session_id, turn_ts
ORDER BY session_id, turn_ts
