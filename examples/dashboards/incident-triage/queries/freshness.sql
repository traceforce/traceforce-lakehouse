-- How current the sources are: findings come from daily snapshots of TraceForce's control plane, blocks
-- from the event logs.
SELECT
  cast((SELECT max(created_at) FROM (
     SELECT created_at FROM sensitive_data_findings
     UNION ALL SELECT created_at FROM connector_containment_findings
     UNION ALL SELECT created_at FROM prompt_injection_findings)) AS varchar) AS findings_through,
  cast((SELECT max(ingested_at) FROM agent_events) AS varchar) AS events_through
