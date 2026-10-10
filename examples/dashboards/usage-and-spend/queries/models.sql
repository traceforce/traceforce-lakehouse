-- One row per (UTC day, agent, model) over the turns that report tokens or cost.
-- `model` is what was requested; selectors such as 'auto' or 'default' are not model names.
SELECT
  cast(date(ts) AS varchar) AS day,
  lower(replace(agent, 'AGENT_IDENTITY_', '')) AS agent,
  coalesce(model, 'unknown') AS model,
  count(*) AS requests,
  sum(input_tokens) AS input_tokens,
  sum(output_tokens) AS output_tokens,
  sum(cache_read_tokens) AS cache_read_tokens,
  sum(cost_usd) AS cost_usd
FROM agent_events
WHERE ts >= date_add('day', -90, current_date)
  AND operation IS DISTINCT FROM 'invoke_agent'
  AND (input_tokens IS NOT NULL OR cost_usd IS NOT NULL)
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3
