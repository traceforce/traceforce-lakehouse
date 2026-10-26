-- BigQuery (GoogleSQL) version of ../findings.sql: every finding from the last 90 days, one row each.
-- Also in traceforce-ui src/lib/lakehouse/queries/incidents.ts (the in-app GCP dashboards): keep the two in sync.
WITH f AS (
  SELECT id, 'sensitive_data' AS kind, conversation_id, device_id, message_timestamp AS `at`, finding_status AS status,
         category, type, CAST(NULL AS STRING) AS outcome,
         -- Where the match is; the matched value itself is never in the lake.
         CASE WHEN file_id IS NOT NULL THEN 'in an attached file' ELSE 'in a message' END
           || CASE WHEN encoding_type IS NOT NULL THEN ' (' || encoding_type || ' encoded)' ELSE '' END AS detail,
         message_external_id, CAST(NULL AS STRING) AS tool_use_id, issue_detail
  FROM traceforce_lakehouse.sensitive_data_findings
  WHERE message_timestamp >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY))
  UNION ALL
  SELECT id, 'risky_action', conversation_id, device_id, detected_at, finding_status,
         risky_action_category, risky_action_subcategory, outcome,
         op || ' via ' || tool_name || CASE WHEN operation <> '' THEN ': ' || operation ELSE '' END,
         NULL, tool_use_id, issue_detail
  FROM traceforce_lakehouse.connector_containment_findings
  WHERE detected_at >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY))
  UNION ALL
  SELECT id, 'prompt_injection', conversation_id, device_id, detected_at, finding_status,
         'prompt_injection', 'prompt_injection', NULL, description, message_external_id, NULL, issue_detail
  FROM traceforce_lakehouse.prompt_injection_findings
  WHERE detected_at >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY))
),
ev AS (
  SELECT session_id, ANY_VALUE(lower(replace(agent, 'AGENT_IDENTITY_', ''))) AS agent
  FROM traceforce_lakehouse.agent_events
  WHERE ts >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 91 DAY)) AND session_id IS NOT NULL
  GROUP BY session_id
)
SELECT
  f.id, f.kind, FORMAT_TIMESTAMP('%F %H:%M:%E6S', f.`at`) AS `at`, CAST(DATE(f.`at`) AS STRING) AS day, f.status,
  f.category, f.type, f.outcome, substr(f.detail, 1, 600) AS detail, f.message_external_id, f.tool_use_id, it.criticality,
  lower(a.agent_email) AS person,
  coalesce(REGEXP_REPLACE(lower(ct.agent_name), r'[^a-z0-9]+', '_'), ev.agent) AS agent,
  c.conversation_external_id AS session_id, c.name AS session_name,
  coalesce(d.friendly_name, d.device_native_id) AS device
FROM f
JOIN traceforce_lakehouse.agent_conversations c ON c.id = f.conversation_id
JOIN traceforce_lakehouse.agent_accounts a ON a.id = c.agent_account_id
LEFT JOIN traceforce_lakehouse.agent_catalog ct ON ct.agent_type = a.agent_type
LEFT JOIN ev ON ev.session_id = c.conversation_external_id
LEFT JOIN traceforce_lakehouse.devices d ON d.id = f.device_id
LEFT JOIN traceforce_lakehouse.issue_types it ON it.issue_detail = f.issue_detail AND it.applicable_to = 'instance'
ORDER BY f.`at`
