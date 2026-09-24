# agent_conversation_files

Files attached to conversations (uploads).

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
| `size_bytes` | long | Attachment size in bytes as reported; NULL for a zero-byte or unreported attachment (never 0). |
| `message_external_id` | string | Agent's id of the message the file was attached to. |
| `message_timestamp` | timestamp | When it was attached (UTC). |
| `archive_inner_path` | string | Entry path when the file is an archive member; '' (never NULL) for a plain file. |
| `customer_storage` | string | JSON text {bucket, key_prefix, region, provider, source_file}: a pointer into the customer's BYO storage bucket; provider is a code, not a name (1 = GCS, 2 = S3, 3 = Azure Blob). On conversations it locates the session's uploaded activity objects; on findings it locates the evidence object holding the verbatim matched value / tool input (the redacted attachment for file findings). NULL when BYO storage is unconfigured or the source object is empty. Evidence is not in the lake by design; see reference/redaction.md. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
