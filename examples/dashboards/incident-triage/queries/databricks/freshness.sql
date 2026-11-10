-- Databricks SQL version of ../freshness.sql.
SELECT
  CAST((SELECT max(created_at) FROM (
     SELECT created_at FROM traceforce_lakehouse.traceforce.sensitive_data_findings
     UNION ALL SELECT created_at FROM traceforce_lakehouse.traceforce.connector_containment_findings
     UNION ALL SELECT created_at FROM traceforce_lakehouse.traceforce.prompt_injection_findings)) AS STRING) AS findings_through,
  CAST((SELECT max(ingested_at) FROM traceforce_lakehouse.traceforce.agent_events) AS STRING) AS events_through
