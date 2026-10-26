-- BigQuery (GoogleSQL) version of ../models.sql: one row per (UTC day, agent, model).
-- Also in traceforce-ui src/lib/lakehouse/queries/usage.ts (the in-app GCP dashboards): keep the two in sync.
SELECT
  CAST(DATE(ts) AS STRING) AS day,
  lower(replace(agent, 'AGENT_IDENTITY_', '')) AS agent,
  coalesce(model, 'unknown') AS model,
  count(*) AS requests,
  sum(input_tokens) AS input_tokens,
  sum(output_tokens) AS output_tokens,
  sum(cache_read_tokens) AS cache_read_tokens,
  sum(cost_usd) AS cost_usd
FROM traceforce_lakehouse.agent_events
WHERE ts >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY))
  AND operation IS DISTINCT FROM 'invoke_agent'
  AND (input_tokens IS NOT NULL OR cost_usd IS NOT NULL)
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3
