-- Follows both rules: quoted lowercase aliases; derived columns grouped by position or a CTE's column.
WITH e AS (
  SELECT LOWER(REPLACE("agent", 'AGENT_IDENTITY_', '')) AS "agent_name", "session_id" AS "session_id"
  FROM "agent_events"
)
SELECT "agent_name" AS "agent", COUNT(DISTINCT "session_id") AS "sessions", CAST(1 AS INTEGER) AS "one"
FROM e
GROUP BY "agent_name"
ORDER BY 1;
SELECT LOWER(REPLACE("agent", 'AGENT_IDENTITY_', '')) AS "agent", COUNT(*) AS "n"
FROM "agent_events"
GROUP BY 1
