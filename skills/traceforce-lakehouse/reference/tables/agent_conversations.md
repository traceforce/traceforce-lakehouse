# agent_conversations

One row per agent session/conversation TraceForce has scanned; created on scan whether or not anything was found. The bridge between findings and the logs; count findings from the findings tables, not from here.

Joins:
- agent_conversations.conversation_external_id = agent_events.session_id
- agent_account_id → agent_accounts.id
- device_id → devices.id
- customer_storage.source_file is the session folder: agent_events.source_object LIKE concat('s3://', bucket, '/', key_prefix, source_file, '%')

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, agent_account_id, conversation_external_id): the SAME external id can exist under two accounts, so a join on conversation_external_id alone may fan out; match the account too when you can

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `device_id` | string | → devices.id |
| `sandbox_id` | string | → sandboxes.id; NULL when the row is about the host device itself. |
| `agent_account_id` | string | → agent_accounts.id |
| `conversation_external_id` | string | The agent's session/conversation id; equals agent_events.session_id. |
| `name` | string | Conversation title as shown in the agent UI; NULL if untitled. |
| `is_archived` | boolean | Archived in the agent UI. |
| `conversation_create_time` | timestamp | Agent-reported creation time (UTC). |
| `conversation_update_time` | timestamp | Agent-reported last update (UTC). |
| `customer_storage` | string | JSON text {bucket, key_prefix, region, provider, source_file}: a pointer into customer S3. On conversations it locates the session's uploaded activity objects; on findings it locates the evidence object holding the verbatim matched value / tool input (the redacted attachment for file findings). Evidence is not in the lake by design; see SKILL.md Redaction and evidence. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
