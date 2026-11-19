-- Breaks the alias rule twice: an unquoted alias (comes back SESSIONS) and a quoted mixed-case one.
SELECT COUNT(*) AS sessions, SUM("cost_usd") AS "Cost_USD"
FROM "agent_events"
