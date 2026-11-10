-- Databricks SQL version of ../freshness.sql.
SELECT CAST(max(ingested_at) AS STRING) AS ingested_through, CAST(max(ts) AS STRING) AS events_through
FROM traceforce_lakehouse.traceforce.agent_events
