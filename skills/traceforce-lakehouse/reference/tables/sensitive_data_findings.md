# sensitive_data_findings

One row per sensitive-data match (a credential, PII value, ...) found in a prompt/response or an attached file. A match is in an attachment when file_id is set, and in message text when file_id IS NULL.

Joins:
- person: conversation_id → agent_conversations.agent_account_id → agent_accounts.agent_email (NOT NULL; every finding has one; no deleted_at filter). Agent name: that agent_accounts row's agent_type → agent_catalog (findings carry no agent_type)
- device owner (secondary, for display): device_id → devices.device_native_id → device_owner_mappings.owner_email
- conversation_id → agent_conversations.id → conversation_external_id = agent_events.session_id
- file_id → agent_conversation_files.id (file name, type, size)

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
| `category` | string | Coarse sensitive-data class as text (e.g. 'credentials'); never NULL, 'unknown' when the rule mapped no class. |
| `type` | string | Specific sensitive-data type as text (e.g. 'ssn', 'email_address'); never NULL, 'unknown' when the rule mapped no type. |
| `start_offset` | long | Character offset of the match start from the start of start_line. |
| `end_offset` | long | Character offset of the match end (exclusive) from the start of end_line; may be < start_offset when end_line > start_line. |
| `start_line` | long | 0-indexed first line of the match within the scanned text (message or attachment). |
| `end_line` | long | 0-indexed last line (inclusive). |
| `part_index` | int | Index of the message part the match is in. |
| `rule_id` | string | Detector rule that fired. |
| `encoding_type` | string | Set when the value was encoded (e.g. base64) and decoded before matching. |
| `archive_inner_path` | string | Path inside a zip/tar when the finding is in an archive entry. |
| `finding_status` | string | Reviewer triage state (text: awaiting_review, under_review, false_positive, revoked, used_in_tests, wont_fix, acknowledged, unknown). Open, as the API counts it, is finding_status IN ('awaiting_review', 'under_review'). Not the enforcement outcome: see reference/enforcement.md (a blocked prompt never produces a finding row). |
| `metadata` | string | JSON text; reviewer close tracking {statusComment, statusUpdatedAt, statusUpdatedBy}; '{}' or NULL until a reviewer closes the finding. |
| `customer_storage` | string | JSON text {bucket, key_prefix, region, provider, source_file}: a pointer into the customer's BYO storage bucket; provider is a code, not a name (1 = GCS, 2 = S3, 3 = Azure Blob). On conversations it locates the session's uploaded activity objects; on findings it locates the evidence object holding the verbatim matched value / tool input (the redacted attachment for file findings). NULL when BYO storage is unconfigured or the source object is empty. Evidence is not in the lake by design; see reference/redaction.md. |
| `conversation_storage` | string | JSON text {bucket, key_prefix, region, provider, source_file}: a pointer into the customer's BYO storage bucket — the exact activity/source object the finding was detected in. Equals agent_events.source_object, the object's storage URI (`s3://…` on AWS, `gs://…` on GCP; = concat(scheme, '://', bucket, '/', key_prefix, source_file)); join on it to get the records of that upload. Only source_file under 'telemetry/' is in the lake; 'conversations/' pointers (browser captures and older uploads) match zero rows. NULL when BYO storage is unconfigured or the finding's source object is empty. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
