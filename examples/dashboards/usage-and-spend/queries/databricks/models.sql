-- Databricks SQL version of ../models.sql: one row per (UTC day, agent, model).
SELECT
  CAST(to_date(ts) AS STRING) AS day,
  lower(replace(agent, 'AGENT_IDENTITY_', '')) AS agent,
  coalesce(model, 'unknown') AS model,
  count(*) AS requests,
  sum(input_tokens) AS input_tokens,
  sum(output_tokens) AS output_tokens,
  sum(cache_read_tokens) AS cache_read_tokens,
  sum(cost_usd) AS cost_usd
FROM traceforce_lakehouse.traceforce.agent_events
WHERE ts >= CAST(date_sub(to_date(timestampadd(MICROSECOND, unix_micros(current_timestamp()), TIMESTAMP_NTZ '1970-01-01 00:00:00')), 90) AS TIMESTAMP_NTZ)
  AND operation IS DISTINCT FROM 'invoke_agent'
  AND (input_tokens IS NOT NULL OR cost_usd IS NOT NULL)
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3
