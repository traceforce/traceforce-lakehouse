-- Databricks SQL version of ../findings.sql: every finding from the last 90 days, one row each.
WITH f AS (
  SELECT id, 'sensitive_data' AS kind, conversation_id, device_id, message_timestamp AS at, finding_status AS status,
         category, type, CAST(NULL AS STRING) AS outcome,
         CASE WHEN file_id IS NOT NULL THEN 'in an attached file' ELSE 'in a message' END
           || CASE WHEN encoding_type IS NOT NULL THEN ' (' || encoding_type || ' encoded)' ELSE '' END AS detail,
         message_external_id, CAST(NULL AS STRING) AS tool_use_id, issue_detail
  FROM traceforce_lakehouse.traceforce.sensitive_data_findings
  WHERE message_timestamp >= CAST(date_sub(to_date(timestampadd(MICROSECOND, unix_micros(current_timestamp()), TIMESTAMP_NTZ '1970-01-01 00:00:00')), 90) AS TIMESTAMP_NTZ)
  UNION ALL
  SELECT id, 'risky_action', conversation_id, device_id, detected_at, finding_status,
         risky_action_category, risky_action_subcategory, outcome,
         op || ' via ' || tool_name || CASE WHEN operation <> '' THEN ': ' || operation ELSE '' END,
         NULL, tool_use_id, issue_detail
  FROM traceforce_lakehouse.traceforce.connector_containment_findings
  WHERE detected_at >= CAST(date_sub(to_date(timestampadd(MICROSECOND, unix_micros(current_timestamp()), TIMESTAMP_NTZ '1970-01-01 00:00:00')), 90) AS TIMESTAMP_NTZ)
  UNION ALL
  SELECT id, 'prompt_injection', conversation_id, device_id, detected_at, finding_status,
         'prompt_injection', 'prompt_injection', NULL, description, message_external_id, NULL, issue_detail
  FROM traceforce_lakehouse.traceforce.prompt_injection_findings
  WHERE detected_at >= CAST(date_sub(to_date(timestampadd(MICROSECOND, unix_micros(current_timestamp()), TIMESTAMP_NTZ '1970-01-01 00:00:00')), 90) AS TIMESTAMP_NTZ)
),
ev AS (
  SELECT session_id, any_value(lower(replace(agent, 'AGENT_IDENTITY_', '')), true) AS agent
  FROM traceforce_lakehouse.traceforce.agent_events
  WHERE ts >= CAST(date_sub(to_date(timestampadd(MICROSECOND, unix_micros(current_timestamp()), TIMESTAMP_NTZ '1970-01-01 00:00:00')), 91) AS TIMESTAMP_NTZ)
    AND session_id IS NOT NULL
  GROUP BY session_id
)
SELECT
  f.id, f.kind, CAST(f.at AS STRING) AS at, CAST(to_date(f.at) AS STRING) AS day, f.status,
  f.category, f.type, f.outcome, substr(f.detail, 1, 600) AS detail, f.message_external_id, f.tool_use_id, it.criticality,
  lower(a.agent_email) AS person,
  coalesce(CASE WHEN a.agent_type RLIKE '^[0-9]*$' THEN NULL ELSE lower(a.agent_type) END,
           regexp_replace(lower(ct.agent_name), '[^a-z0-9]+', '_'), ev.agent) AS agent,
  c.conversation_external_id AS session_id, c.name AS session_name,
  coalesce(d.friendly_name, d.device_native_id) AS device
FROM f
JOIN traceforce_lakehouse.traceforce.agent_conversations c ON c.id = f.conversation_id
JOIN traceforce_lakehouse.traceforce.agent_accounts a ON a.id = c.agent_account_id
LEFT JOIN traceforce_lakehouse.traceforce.agent_catalog ct ON ct.agent_type = a.agent_type
LEFT JOIN ev ON ev.session_id = c.conversation_external_id
LEFT JOIN traceforce_lakehouse.traceforce.devices d ON d.id = f.device_id
LEFT JOIN traceforce_lakehouse.traceforce.issue_types it ON it.issue_detail = f.issue_detail AND it.applicable_to = 'instance'
ORDER BY f.at
