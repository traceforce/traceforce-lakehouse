# prompt_injection_findings

One row per distinct prompt-injection attempt (assistant reply + sanitized description) the agent flagged. A detection record only: nothing was denied or blocked.

Joins:
- person: conversation_id → agent_conversations.agent_account_id → agent_accounts.agent_email (NOT NULL; every finding has one). Do NOT filter agent_accounts.deleted_at here: findings on since-removed accounts still belong to that person. Agent name: that agent_accounts row's agent_type → agent_catalog (findings carry no agent_type)
- device owner (secondary, for display): device_id → devices.device_native_id → device_owner_mappings.owner_email
- conversation_id → agent_conversations.id → conversation_external_id = agent_events.session_id; the flagged reply is that session's row with json_extract_scalar(attrs_json, '$["gen_ai.response.id"]') = message_external_id
- conversation_storage pointer → agent_events.source_object (the exact uploaded object the flag was stored in)

Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):
- (org_id, conversation_id, message_external_id, description), NULLs compared as equal: one row per flagged message per distinct description

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `org_id` | string | Your TraceForce org id. Constant within this lakehouse. |
| `device_id` | string | → devices.id |
| `sandbox_id` | string | → sandboxes.id; NULL when the row is about the host device itself. |
| `conversation_id` | string | → agent_conversations.id (TraceForce uuid, NOT the agent's session id). |
| `message_external_id` | string | The agent's own id of the assistant reply that carried the flag (a Claude response id; only Claude-family agents raise these findings). |
| `description` | string | Short, sanitized summary of the attack pattern the agent flagged: no user data, secrets or file contents (length-capped and scrubbed on the device). NULL when the flag carried none. The origin label and the quoted instruction are in the flagged reply itself: its leading [PI_DETECTED source=… instruction=… description=…] line(s) in agent_events.content_output, masked only where a sensitive value matched; customer_storage points at the same text as an evidence object. |
| `detected_at` | timestamp | When the flagged reply was sent (UTC): the column to bound a period on; created_at is when TraceForce recorded it. Can be NULL. |
| `finding_status` | string | Reviewer triage state (text: awaiting_review, under_review, false_positive, revoked, used_in_tests, wont_fix, acknowledged, unknown). Open, as the API counts it, is finding_status IN ('awaiting_review', 'under_review'). |
| `metadata` | string | JSON text; reviewer close tracking {statusComment, statusUpdatedAt, statusUpdatedBy}; '{}' or NULL until a reviewer closes the finding. |
| `customer_storage` | string | JSON text {bucket, key_prefix, region, provider, source_file}: a pointer into the customer's BYO storage bucket. On conversations it locates the session's uploaded activity objects; on findings it locates the evidence object holding the verbatim matched value / tool input (the redacted attachment for file findings). NULL when BYO storage is unconfigured or the source object is empty. Evidence is not in the lake by design; see reference/redaction.md. |
| `conversation_storage` | string | JSON text {bucket, key_prefix, region, provider, source_file}: a pointer into the customer's BYO storage bucket — the exact activity/source object the finding was detected in. Equals agent_events.source_object, the object's storage URI (`s3://…` on AWS, `gs://…` on GCP; = concat(scheme, '://', bucket, '/', key_prefix, source_file)); join on it to get the records of that upload. NULL when BYO storage is unconfigured or the finding's source object is empty. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
