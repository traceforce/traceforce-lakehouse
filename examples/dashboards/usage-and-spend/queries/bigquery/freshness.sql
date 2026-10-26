-- BigQuery (GoogleSQL) version of ../freshness.sql.
-- Also in traceforce-ui src/lib/lakehouse/queries/usage.ts (the in-app GCP dashboards): keep the two in sync.
SELECT FORMAT_TIMESTAMP('%F %H:%M:%E6S', max(ingested_at)) AS ingested_through,
       FORMAT_TIMESTAMP('%F %H:%M:%E6S', max(ts)) AS events_through
FROM traceforce_lakehouse.agent_events
