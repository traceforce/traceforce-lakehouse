-- Snowflake SQL version of ../blocks.sql: actions TraceForce blocked in the last 90 days.
-- attrs_json holds a JSON object (the ingest writes it with TO_JSON). A quoted path step takes the dotted key
-- as one name. AS_VARCHAR returns the value only when it is a JSON string, and NULL for an object or array,
-- as json_extract_scalar does (::VARCHAR would return the object's JSON text). json_extract_scalar also
-- returns numbers and booleans as text, but none of those can equal 'hook' or contain '[Traceforce'.
WITH e AS (
  SELECT
    LOWER(REPLACE(ev."agent", 'AGENT_IDENTITY_', '')) AS "agent",
    COALESCE(LOWER(ev."user_email"), LOWER(m."owner_email")) AS "person",
    ev."session_id", ev."ts", ev."tool_name", ev."tool_args", ev."mcp_server_name",
    CASE
      WHEN ev."event_name" = 'tool_decision' AND ev."decision" = 'reject'
           AND AS_VARCHAR(TRY_PARSE_JSON(ev."attrs_json"):"source") = 'hook' THEN 'tool_call'
      WHEN ev."event_name" = 'postToolUseFailure' AND ev."error_type" = 'permission_denied'
           AND AS_VARCHAR(TRY_PARSE_JSON(ev."attrs_json"):"cursor.error.message") LIKE '%[Traceforce%'
           AND ev."containment_enforcement" IN ('warn', 'block') THEN 'tool_call'
      WHEN ev."event_name" = 'user_prompt' AND ev."sd_enforcement" = 'block'
           AND ev."content_input" LIKE '%********%' THEN 'prompt'
    END AS "blocked"
  FROM "agent_events" ev
  LEFT JOIN "device_owner_mappings" m ON m."device_native_id" = ev."device_native_id"
  WHERE ev."ts" >= DATEADD('day', -90, CURRENT_DATE())::TIMESTAMP_NTZ
    AND ev."event_name" IN ('tool_decision', 'postToolUseFailure', 'user_prompt')
)
SELECT
  TO_CHAR("ts", 'YYYY-MM-DD HH24:MI:SS.FF6') AS "at", TO_CHAR("ts"::DATE, 'YYYY-MM-DD') AS "day", "agent", "person",
  "session_id", "blocked",
  CASE WHEN "blocked" = 'prompt' THEN 'prompt with sensitive data'
       WHEN "mcp_server_name" IS NOT NULL THEN "mcp_server_name" || '/' || COALESCE("tool_name", '?')
       ELSE COALESCE("tool_name", 'tool') END AS "detail",
  SUBSTR("tool_args", 1, 600) AS "tool_args"
FROM e
WHERE "blocked" IS NOT NULL
ORDER BY "ts"
