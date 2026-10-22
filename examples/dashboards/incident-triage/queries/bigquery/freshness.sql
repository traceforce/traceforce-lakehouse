-- BigQuery (GoogleSQL) version of ../freshness.sql.
SELECT
  FORMAT_TIMESTAMP('%F %H:%M:%E6S', (SELECT max(created_at) FROM (
     SELECT created_at FROM traceforce_lakehouse.sensitive_data_findings
     UNION ALL SELECT created_at FROM traceforce_lakehouse.connector_containment_findings
     UNION ALL SELECT created_at FROM traceforce_lakehouse.prompt_injection_findings))) AS findings_through,
  FORMAT_TIMESTAMP('%F %H:%M:%E6S', (SELECT max(ingested_at) FROM traceforce_lakehouse.agent_events)) AS events_through
