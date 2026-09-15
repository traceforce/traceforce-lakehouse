# agent_conversation_files

Files attached to conversations (uploads). What a file finding points at.

Joins:
- agent_conversation_files.id = sensitive_data_findings.file_id
- conversation_id → agent_conversations.id

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, conversation_id, message_external_id, file_external_id, archive_inner_path)

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `device_id` | string | → devices.id |
| `sandbox_id` | string | → sandboxes.id; NULL when the row is about the host device itself. |
| `conversation_id` | string | → agent_conversations.id |
| `file_external_id` | string | Agent's own file id. |
| `file_name` | string | Original filename. |
| `mime_type` | string | MIME type. |
| `size_bytes` | long | Size in bytes. |
| `message_external_id` | string | Agent's id of the message the file was attached to. |
| `message_timestamp` | timestamp | When it was attached (UTC). |
| `archive_inner_path` | string | Entry path when the file is an archive member. |
| `customer_storage` | string | JSON text {bucket, key_prefix, region, provider, source_file}. On conversations source_file is the session FOLDER (conversations/<agent>/dt=<YYYYMMDD>/<serial>/<account>/<session>/ for collector 1.0.42+, no dt= segment before; a session spanning midnight has two). On findings it is the EVIDENCE object under findings/<agent>/<serial>/<account>/<session>/evidence/ (verbatim matched value / verbatim tool input; for file findings the redacted attachment). Evidence is NOT in the lake by design; see SKILL.md Redaction and evidence. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
