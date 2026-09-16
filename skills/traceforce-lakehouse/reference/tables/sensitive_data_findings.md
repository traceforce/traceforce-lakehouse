# sensitive_data_findings

One row per sensitive-data match (a credential, PII value, ...) found in a prompt/response or an attached file. Most findings come from attached files rather than prompt text; always handle both paths (file_id NULL = message finding).

Joins:
- person: conversation_id → agent_conversations.agent_account_id → agent_accounts.agent_email (NOT NULL; every finding has one). Do NOT filter agent_accounts.deleted_at here: findings on since-removed accounts still belong to that person. agent_type → agent_catalog for the agent name
- device owner (secondary, for display): device_id → devices.device_native_id → device_owner_mappings.owner_email
- conversation_id → agent_conversations.id → conversation_external_id = agent_events.session_id
- file_id → agent_conversation_files.id (file name, type, size)
- conversation_storage pointer → agent_events.source_object (the exact uploaded object the match was found in)

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, conversation_id, message_external_id, file_id, part_index, start_offset, end_offset, start_line, end_line, rule_id): one row per match location

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `device_id` | string | → devices.id |
| `sandbox_id` | string | → sandboxes.id; NULL when the row is about the host device itself. |
| `conversation_id` | string | → agent_conversations.id (TraceForce uuid, NOT the agent's session id). |
| `file_id` | string | → agent_conversation_files.id when the match is in an attachment; NULL for message findings. |
| `message_external_id` | string | The agent's own id of the source message (Claude prompt/response id, Cursor generation id). |
| `message_timestamp` | timestamp | When the message was sent (UTC): the column to bound a period on; created_at is when TraceForce recorded it. |
| `category` | string | Coarse class of the match. |
| `type` | string | Exact data type of the match. |
| `start_offset` | long | Character offset of the match start within the scanned text. |
| `end_offset` | long | Character offset of the match end (exclusive). |
| `start_line` | long | 0-indexed first line of the match within the scanned text (message or attachment). Not a message/file discriminator: use file_id IS NULL for message findings. |
| `end_line` | long | 0-indexed last line (inclusive). |
| `part_index` | int | Index of the message part the match is in. |
| `rule_id` | string | Detector rule that fired. |
| `encoding_type` | string | Set when the value was encoded (e.g. base64) and decoded before matching. |
| `archive_inner_path` | string | Path inside a zip/tar when the finding is in an archive entry. |
| `finding_status` | string | Reviewer triage state (text: awaiting_review, under_review, false_positive, revoked, used_in_tests, wont_fix, acknowledged, unknown). Open, as the API counts it, is finding_status IN ('awaiting_review', 'under_review'). Not the enforcement outcome: see SKILL.md, Enforcement outcomes (a blocked prompt never produces a finding row). |
| `metadata` | string | JSON text; vendor-specific extras (e.g. version). |
| `customer_storage` | string | JSON text {bucket, key_prefix, region, provider, source_file}. On conversations source_file is the session FOLDER (conversations/<agent>/dt=<YYYYMMDD>/<serial>/<account>/<session>/ for collector 1.0.42+, no dt= segment before; a session spanning midnight has two). On findings it is the EVIDENCE object under findings/<agent>/<serial>/<account>/<session>/evidence/ (verbatim matched value / verbatim tool input; for file findings the redacted attachment). Evidence is NOT in the lake by design; see SKILL.md Redaction and evidence. |
| `conversation_storage` | string | JSON text {bucket, key_prefix, region, provider, source_file}: the exact activity object the finding was detected in. Equals agent_events.source_object when written as concat('s3://', bucket, '/', key_prefix, source_file); join on it to get the records of that upload. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
