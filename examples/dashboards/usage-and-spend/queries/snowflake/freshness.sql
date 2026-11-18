-- Snowflake SQL version of ../freshness.sql. Six fraction digits always, so the values sort as strings.
SELECT TO_CHAR(MAX("ingested_at"), 'YYYY-MM-DD HH24:MI:SS.FF6') AS "ingested_through",
  TO_CHAR(MAX("ts"), 'YYYY-MM-DD HH24:MI:SS.FF6') AS "events_through"
FROM "agent_events"
