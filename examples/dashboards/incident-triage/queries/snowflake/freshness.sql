-- Snowflake SQL version of ../freshness.sql. Six fraction digits always, so the values sort as strings.
SELECT
  TO_CHAR((SELECT MAX("created_at") AS "created_at" FROM (
     SELECT "created_at" FROM "sensitive_data_findings"
     UNION ALL SELECT "created_at" FROM "connector_containment_findings"
     UNION ALL SELECT "created_at" FROM "prompt_injection_findings")), 'YYYY-MM-DD HH24:MI:SS.FF6') AS "findings_through",
  TO_CHAR((SELECT MAX("ingested_at") AS "ingested_at" FROM "agent_events"), 'YYYY-MM-DD HH24:MI:SS.FF6') AS "events_through"
