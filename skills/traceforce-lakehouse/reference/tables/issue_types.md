# issue_types

Global reference: every issue type TraceForce raises, with its risk score and criticality.

Joins:
- issue_types.id = issue_type_controls.issue_type_id
- A finding's issue_detail = issue_types.issue_detail AND issue_types.applicable_to = 'instance' (one row per issue_detail and applicable_to, so pin it)

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (issue_detail, applicable_to): one issue_detail can have an 'instance' and a 'global' row

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `risk_rule_id` | string | The risk rule the type belongs to (that table is not in the lake). |
| `entity_type` | string | Which issues use it: 'agent' (agent_issues) or 'mcp' (mcp_server_issues). |
| `issue_detail` | string | The specific condition, as text (e.g. 'agent_sensitive_data_credentials_detected'). The findings tables carry the same value in their issue_detail column. |
| `applicable_to` | string | 'instance': a controllable issue raised from what scout detects on an install; findings map only to these. 'global': a baseline issue raised because the agent is present at all, not tied to findings (acknowledgment-only in the console, which lists 'instance' types). |
| `trigger_score` | double | Risk score (0-100) an issue of this type carries; drives the console's risk badge. |
| `criticality` | string | trigger_score in the console's risk-badge bands: 'low' (below 40), 'medium' (below 60), 'high' (below 80), else 'critical'. |
| `name` | string | Display name. |
| `description` | string | What the issue means; NULL when none. |
| `remediation_text` | string | How to fix it, as shown in the console; '' when none. |
| `expected_value` | string | The setting that avoids the issue, as display text (e.g. 'On (Prompt Injection Detection)'); NULL when none. |
| `display_order` | int | Console sort order; NULL when unset. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
