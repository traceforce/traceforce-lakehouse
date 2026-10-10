-- Every finding from the last 90 days, one row each, in one shape across the three findings tables.
-- The page groups them into incidents (one per session) and ranks those by severity.
-- Person is the conversation's signed-in account (no deleted_at filter: a signed-out account still owns its
-- past findings). Agent is that account's catalog entry (by agent_type) as a key like 'claude_code'; older
-- lakehouses leave agent_type empty, so it falls back to the agent the session's events name, else NULL.
WITH f AS (
  SELECT id, 'sensitive_data' AS kind, conversation_id, device_id, message_timestamp AS at, finding_status AS status,
         category, type, NULL AS outcome,
         -- Where the match is; the matched value itself is never in the lake.
         CASE WHEN file_id IS NOT NULL THEN 'in an attached file' ELSE 'in a message' END
           || CASE WHEN encoding_type IS NOT NULL THEN ' (' || encoding_type || ' encoded)' ELSE '' END AS detail,
         message_external_id, NULL AS tool_use_id
  FROM sensitive_data_findings
  WHERE message_timestamp >= date_add('day', -90, current_date)
  UNION ALL
  SELECT id, 'risky_action', conversation_id, device_id, detected_at, finding_status,
         risky_action_category, risky_action_subcategory, outcome,
         op || ' via ' || tool_name || CASE WHEN operation <> '' THEN ': ' || operation ELSE '' END,
         NULL, tool_use_id
  FROM connector_containment_findings
  WHERE detected_at >= date_add('day', -90, current_date)
  UNION ALL
  SELECT id, 'prompt_injection', conversation_id, device_id, detected_at, finding_status,
         'prompt_injection', 'prompt_injection', NULL, description, message_external_id, NULL
  FROM prompt_injection_findings
  WHERE detected_at >= date_add('day', -90, current_date)
),
ev AS (
  SELECT session_id, arbitrary(lower(replace(agent, 'AGENT_IDENTITY_', ''))) AS agent
  FROM agent_events
  WHERE ts >= date_add('day', -91, current_date) AND session_id IS NOT NULL
  GROUP BY session_id
)
SELECT
  f.id, f.kind, cast(f.at AS varchar) AS at, cast(date(f.at) AS varchar) AS day, f.status,
  f.category, f.type, f.outcome, substr(f.detail, 1, 600) AS detail, f.message_external_id, f.tool_use_id,
  lower(a.agent_email) AS person,
  coalesce(regexp_replace(lower(ct.agent_name), '[^a-z0-9]+', '_'), ev.agent) AS agent,
  c.conversation_external_id AS session_id, c.name AS session_name,
  coalesce(d.friendly_name, d.device_native_id) AS device
FROM f
JOIN agent_conversations c ON c.id = f.conversation_id
JOIN agent_accounts a ON a.id = c.agent_account_id
LEFT JOIN agent_catalog ct ON ct.agent_type = a.agent_type
LEFT JOIN ev ON ev.session_id = c.conversation_external_id
LEFT JOIN devices d ON d.id = f.device_id
ORDER BY f.at
