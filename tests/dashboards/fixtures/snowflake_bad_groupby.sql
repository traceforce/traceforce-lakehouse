-- Breaks the GROUP BY rule: "agent" is both a source column and the alias of a derived value, so
-- Snowflake groups by the raw column and splits the rows.
SELECT LOWER(REPLACE("agent", 'AGENT_IDENTITY_', '')) AS "agent", COUNT(*) AS "n"
FROM "agent_events"
GROUP BY "agent"
