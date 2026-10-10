-- How current the lake is: newest loaded row and newest event time (UTC). Informational only.
SELECT cast(max(ingested_at) AS varchar) AS ingested_through, cast(max(ts) AS varchar) AS events_through
FROM agent_events
