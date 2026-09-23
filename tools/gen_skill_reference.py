#!/usr/bin/env python3
"""Generate the skill's schema reference from the Terraform column lists.

Single source of truth for column names/types is terraform/aws/ (exports.tf for the mirrors,
s3tables.tf for agent_events) — the column lists are the same schema on both clouds. This
script adds meaning: per-column notes and join rules, and writes
skills/traceforce-lakehouse/reference/*.md. Re-run after changing either .tf file; commit the output.

Enum columns are decoded to human-readable text at export time (decode-at-export), so the
mirror already stores strings (e.g. op = 'delete', category = 'credentials',
finding_status = 'awaiting_review'); there is no integer-decode ring here. The only codes
left are the join keys agent_type and mcp_server_type, resolved via the catalogs.
"""
import re, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
# Drift risk: the column lists live in TWO hand-maintained places now. We read the AWS module
# (terraform/aws/{exports,s3tables}.tf); terraform/gcp/locals.tf keeps its OWN copy of the same
# lists (agent_events_schema / export_tables) to build the BigQuery tables. They are meant to be
# identical ("identical contract"), but nothing enforces it -- edit columns in one module and not
# the other and they silently diverge, and this reference (generated from AWS only) is then wrong
# for GCP. Keep both .tf in sync when changing columns, or add a check that fails when they differ.
TF = ROOT / "terraform" / "aws"
OUT = ROOT / "skills" / "traceforce-lakehouse" / "reference"

# ----------------------------------------------------------------------------- tables

# Postgres unique constraints (informational: Iceberg/Athena enforce nothing; the mirror is keyed by id).
UNIQUE = {
    "devices": ["(org_id, coalesce(device_uuid, device_native_id)): one row per device; a Windows device keyed by GUID may share its serial with others"],
    "sandboxes": ["(org_id, parent_device_id, sandbox_native_id)"],
    "agent_accounts": ["(org_id, device_id, sandbox_id, agent_type, agent_email, agent_org_id), NULLs compared as equal: the same email can have one row per device, per agent, per vendor org"],
    "agent_instances": ["(org_id, device_id, sandbox_id, tenant, agent_type, agent_deployment): one install per OS user and form factor"],
    "agent_instances_accounts": ["(org_id, device_id, sandbox_id, agent_instance_id, agent_account_id)"],
    "device_owner_mappings": ["(org_id, device_native_id): at most one owner per serial"],
    "agent_catalog": ["agent_type", "agent_name", "website"],
    "sensitive_data_findings": ["(org_id, conversation_id, message_external_id, file_id, part_index, start_offset, end_offset, start_line, end_line, rule_id): one row per match location"],
    "connector_containment_findings": ["(org_id, conversation_id, tool_use_id): one row per tool call"],
    "agent_conversations": ["(org_id, agent_account_id, conversation_external_id): the SAME external id can exist under two accounts, so a join on conversation_external_id alone may fan out; match the account too when you can"],
    "agent_conversation_files": ["(org_id, conversation_id, message_external_id, file_external_id, archive_inner_path)"],
    "mcp_server_instances": ["(org_id, device_id, sandbox_id, agent_account_id, mcp_server_location, mcp_native_id, project_path): the same server name can appear once per project path"],
    "mcp_server_agent_instances": ["(org_id, device_id, sandbox_id, agent_instance_id, mcp_server_instance_id)"],
    "mcp_servers": ["(org_id, mcp_server_type): one rollup per product per org"],
    "mcp_catalog": ["mcp_server_type", "mcp_server_name"],
    "org_mcp_catalog": ["(org_id, mcp_server_type)", "(org_id, mcp_server_name)"],
    "mcp_categories": ["id only"],
}
COMMON = {
    "id": "Primary key (uuid as text).",
    "org_id": "Your TraceForce org id. Constant within this lakehouse.",
    "created_at": "Row created (UTC).",
    "updated_at": "Row last updated (UTC).",
    "last_seen_at": "Most recent check-in that observed this row (UTC).",
    "last_active_at": "Most recent activity (UTC); NULL if never active.",
    "deleted_at": "Soft delete. NULL = live. Filter `deleted_at IS NULL` for the current inventory.",
    "device_id": "→ devices.id",
    "sandbox_id": "→ sandboxes.id; NULL when the row is about the host device itself.",
    "metadata": "JSON text; vendor-specific extras (e.g. version).",
    "customer_storage": "JSON text {bucket, key_prefix, region, provider, source_file}: a pointer into the customer's BYO storage bucket. On conversations it locates the session's uploaded activity objects; on findings it locates the evidence object holding the verbatim matched value / tool input (the redacted attachment for file findings). NULL when BYO storage is unconfigured or the source object is empty. Evidence is not in the lake by design; see reference/redaction.md.",
    "conversation_storage": "JSON text {bucket, key_prefix, region, provider, source_file}: a pointer into the customer's BYO storage bucket — the exact activity/source object the finding was detected in. Equals agent_events.source_object, the object's storage URI (`s3://…` on AWS, `gs://…` on GCP; = concat(scheme, '://', bucket, '/', key_prefix, source_file)); join on it to get the records of that upload. NULL when BYO storage is unconfigured or the finding's source object is empty.",
    "description": "Catalog description.",
    "website": "Vendor website.",
    "logo_url": "Logo URL.",
}
TABLES = {
    "devices": dict(
        purpose="One row per device TraceForce has seen (laptops, workstations). The anchor for every join from the logs.",
        joins=["agent_events.device_uuid = devices.device_uuid when the event has one (Windows), else agent_events.device_native_id = devices.device_native_id"],
        notes={"device_native_id": "OS-reported serial (e.g. C02XXXXXXXXX on macOS). Same value as agent_events.device_native_id. Windows serials can be placeholders shared by many machines.",
               "device_uuid": "Windows per-install GUID; NULL on macOS/Linux. Prefer it over the serial for the device join when present.",
               "friendly_name": "Human-readable name (e.g. Jane's MacBook Pro).", "platform": "darwin / windows / linux.",
               "architecture": "CPU architecture (arm64, amd64).", "os_version": "OS version string.", "chip_model": "Chip model when reported.",
               "account_metadata": "JSON text keyed by OS uid/SID with the OS username; how agent_instances.tenant resolves to a username."}),
    "sandboxes": dict(
        purpose="Devcontainers / cloud VMs an agent ran in. The parent host is a row in devices.",
        joins=["sandboxes.parent_device_id = devices.id", "agent_events.sandbox_native_id = sandboxes.sandbox_native_id (reserved; NULL in events today)"],
        notes={"parent_device_id": "→ devices.id of the host.", "sandbox_native_id": "Sandbox identifier; join key to agent_events.sandbox_native_id.",
               "runtime_type": "Sandbox runtime as text ('devcontainer' / 'unspecified').", "workspace_folder": "Workspace path inside the sandbox.", "friendly_name": "Display name.",
               "os_version": "Guest OS version.", "account_metadata": "JSON text; OS users inside the sandbox."}),
    "agent_accounts": dict(
        purpose="One row per signed-in account: (device, agent, email, vendor org). Who is behind an event.",
        joins=["agent_accounts.device_id = devices.id AND agent_accounts.agent_type = agent_events.agent_type AND lower(agent_accounts.agent_email) = lower(agent_events.user_email) (enrichment of an event with plan / vendor org; the person is already user_email)",
               "agent_accounts.agent_org_id = agent_events.agent_org_id when both are non-NULL (Claude family)",
               "When reached by id from agent_conversations.agent_account_id, do NOT filter deleted_at: a signed-out account still owns its past findings (this is what the console does)"],
        notes={"agent_type": "Which agent product.", "plan": "Account plan (decoded AgentPlanType text, e.g. 'personal', 'enterprise', 'small_business'; 'unknown' for AgentPlanType 0). The console's notion of an agent is an INSTALL's (agent_type, coalesce(plan, 'unknown')): start from agent_instances, LEFT JOIN agent_instances_accounts and agent_accounts; installs with no signed-in account are plan 'unknown'. Never count agents from agent_accounts alone.", "tier": "Vendor plan tier text when known.",
               "agent_email": "Email the user authenticated to the agent with. Stored byte-exact; lower() is a tolerance.",
               "agent_org_id": "The AI vendor's workspace/org id (e.g. the Anthropic org for Claude); NULL when the agent has no workspace/org concept.",
               "agent_id": "→ the org-level agent rollup (that table is not in the lake).",
               "security_settings": "JSON text; vendor security settings observed for the account.",
               "models_configuration": "JSON text; models configured for the account."}),
    "agent_instances": dict(
        purpose="Installs: one row per (device, agent, deployment form factor, OS user). Includes agents that never produce an account (Copilot).",
        joins=["agent_instances.device_id = devices.id AND agent_instances.agent_type = agent_events.agent_type",
               "agent_instances_accounts links an install to the accounts signed in through it"],
        notes={"agent_type": "Which agent product.", "agent_deployment": "Form factor of this install, as text ('desktop_app' / 'vscode_extension' / 'cli' / 'browser' / 'ai_browser' / 'service' / 'unknown').",
               "tenant": "OS-level user (uid on macOS/Linux, SID on Windows) the install belongs to; resolve to a username via devices.account_metadata.",
               "agent_catalog_id": "→ agent_catalog.id", "configuration": "JSON text; detected agent configuration.",
               "installations": "JSON text; filesystem installation records (paths, versions)."}),
    "agent_instances_accounts": dict(
        purpose="Junction: which account is signed in through which install.",
        joins=["agent_instance_id → agent_instances.id", "agent_account_id → agent_accounts.id",
               "No deleted_at of its own. A link is live only when BOTH parents are: agent_instances.deleted_at IS NULL AND agent_accounts.deleted_at IS NULL (the console's active_agent_instances_accounts view)"],
        notes={"agent_instance_id": "→ agent_instances.id", "agent_account_id": "→ agent_accounts.id"}),
    "device_owner_mappings": dict(
        purpose="Device owner from your MDM. The attribution path for agents whose logs carry no email.",
        joins=["device_owner_mappings.device_native_id = agent_events.device_native_id (or = devices.device_native_id)"],
        notes={"mdm_integration_id": "Which MDM integration produced the mapping.", "device_native_id": "Serial as reported by the MDM.",
               "owner_email": "Owner/assigned-user email from your MDM; NULL for shared or bulk-enrolled devices with no assigned user.", "owner_name": "Owner display name from the MDM."}),
    "agent_catalog": dict(
        purpose="Global reference: agent_type → product name, one row per known agent type.",
        joins=["agent_catalog.agent_type = agent_instances.agent_type (or agent_accounts / agent_events.agent_type)"],
        notes={"agent_name": "Display name (Claude Code, Cursor, GitHub Copilot, ChatGPT, ...).", "agent_type": "The integer code used everywhere else; join key, not decoded.",
               "domain": "Vendor domain."}),
    "sensitive_data_findings": dict(
        purpose="One row per sensitive-data match (a credential, PII value, ...) found in a prompt/response or an attached file. A match is in an attachment when file_id is set, and in message text when file_id IS NULL; handle both.",
        joins=["person: conversation_id → agent_conversations.agent_account_id → agent_accounts.agent_email (NOT NULL; every finding has one). Do NOT filter agent_accounts.deleted_at here: findings on since-removed accounts still belong to that person. agent_type → agent_catalog for the agent name",
               "device owner (secondary, for display): device_id → devices.device_native_id → device_owner_mappings.owner_email",
               "conversation_id → agent_conversations.id → conversation_external_id = agent_events.session_id",
               "file_id → agent_conversation_files.id (file name, type, size)",
               "conversation_storage pointer → agent_events.source_object (the exact uploaded object the match was found in)"],
        notes={"conversation_id": "→ agent_conversations.id (TraceForce uuid, NOT the agent's session id).",
               "file_id": "→ agent_conversation_files.id when the match is in an attachment; NULL for message findings.",
               "message_external_id": "The agent's own id of the source message (Claude prompt/response id, Cursor generation id).",
               "message_timestamp": "When the message was sent (UTC): the column to bound a period on; created_at is when TraceForce recorded it.", "category": "Coarse sensitive-data class as text (e.g. 'credentials'); never NULL, 'unknown' when the rule mapped no class.", "type": "Specific sensitive-data type as text (e.g. 'ssn', 'email_address'); never NULL, 'unknown' when the rule mapped no type.",
               "start_offset": "Character offset of the match start within the scanned text.", "end_offset": "Character offset of the match end (exclusive).",
               "start_line": "0-indexed first line of the match within the scanned text (message or attachment). Not a message/file discriminator: use file_id IS NULL for message findings.", "end_line": "0-indexed last line (inclusive).",
               "part_index": "Index of the message part the match is in.", "rule_id": "Detector rule that fired.",
               "encoding_type": "Set when the value was encoded (e.g. base64) and decoded before matching.",
               "archive_inner_path": "Path inside a zip/tar when the finding is in an archive entry.",
               "finding_status": "Reviewer triage state (text: awaiting_review, under_review, false_positive, revoked, used_in_tests, wont_fix, acknowledged, unknown). Open, as the API counts it, is finding_status IN ('awaiting_review', 'under_review'). Not the enforcement outcome: see reference/enforcement.md (a blocked prompt never produces a finding row)."}),
    "connector_containment_findings": dict(
        purpose="One row per write/delete a tool attempted through a connector (MCP, Bash, Write). Denied attempts are NOT stored; only executed/failed ones.",
        joins=["person: conversation_id → agent_conversations.agent_account_id → agent_accounts (no deleted_at filter); device owner via device_id → devices → device_owner_mappings",
               "tool_use_id = agent_events.tool_call_id (same session); the tool_decision row carries the approval source. Cursor rows carry no tool_decision, so join tool_use_id to the finding's tool_result/span row instead",
               "conversation_id → agent_conversations.id → agent_events.session_id", "device_id → devices.id",
               "conversation_storage pointer → agent_events.source_object (the exact uploaded object)"],
        notes={"conversation_id": "→ agent_conversations.id", "op": "Kind of mutation: always 'write' or 'delete' (never NULL; denied/unknown are filtered out).", "tool_name": "Tool that attempted it (Write, Bash, MCP:<server>).",
               "operation": "Display-safe subject of the op: an MCP tool's bare name, or a file path, redacted and truncated to 512 bytes; '' (empty string) for shell/command ops (Bash/Shell) and decision-only rows; the verbatim command never lands here, only in customer_storage — read the actual tool input from the joined agent_events.tool_args.",
               "tool_use_id": "Agent's tool-call id; equals agent_events.tool_call_id.", "prompt_id": "Id of the prompt/turn that triggered the op, but this table does not populate it (NULL here) \u2014 do not filter or aggregate this column. It matches agent_events.prompt_id, so reach the triggering turn (the prompt plus its sibling tool calls) by joining tool_use_id \u2192 agent_events.tool_call_id and using that row's prompt_id.",
               "hook_event_name": "Hook that observed it (e.g. PreToolUse).", "detected_at": "When the op was observed (UTC); the reliable order-by time for containment findings; effectively always set.",
               "finding_status": "Reviewer triage state as text (same set as sensitive_data_findings.finding_status); never NULL, starts 'awaiting_review'.", "outcome": "Execution result as text ('executed' / 'failed' / 'unspecified'); never NULL, never 'denied' (denied attempts aren't stored)."}),
    "agent_conversations": dict(
        purpose="One row per agent session/conversation TraceForce has scanned; created on scan whether or not anything was found. The bridge between findings and the logs; count findings from the findings tables, not from here.",
        joins=["agent_conversations.conversation_external_id = agent_events.session_id", "agent_account_id → agent_accounts.id", "device_id → devices.id",
               "customer_storage.source_file is the session folder: agent_events.source_object LIKE concat(scheme, '://', bucket, '/', key_prefix, source_file, '%'), where scheme is 's3' on AWS and 'gs' on GCP (a hardcoded 's3://' matches zero rows on GCP)"],
        notes={"agent_account_id": "→ agent_accounts.id", "conversation_external_id": "The agent's session/conversation id; equals agent_events.session_id.",
               "name": "Conversation title as shown in the agent UI; NULL if untitled.", "is_archived": "Archived in the agent UI.",
               "conversation_create_time": "Agent-reported creation time (UTC).", "conversation_update_time": "Agent-reported last update (UTC)."}),
    "agent_conversation_files": dict(
        purpose="Files attached to conversations (uploads). What a file finding points at.",
        joins=["agent_conversation_files.id = sensitive_data_findings.file_id", "conversation_id → agent_conversations.id"],
        notes={"conversation_id": "→ agent_conversations.id", "file_external_id": "Agent's own file id.", "file_name": "Original filename.",
               "mime_type": "MIME type.", "size_bytes": "Attachment size in bytes as reported; NULL for a zero-byte or unreported attachment (never 0).", "message_external_id": "Agent's id of the message the file was attached to.",
               "message_timestamp": "When it was attached (UTC).", "archive_inner_path": "Entry path when the file is an archive member."}),
    "mcp_server_instances": dict(
        purpose="MCP servers configured on a device for an agent. The MCP inventory; the name matches what the logs carry.",
        joins=["lower(mcp_server_instances.mcp_native_id) = lower(agent_events.mcp_server_name) AND same device_id/agent_type. Not a key: the same server name can have several live rows per device (one per project_path or location), so aggregate or SELECT DISTINCT",
               "account: agent_account_id when set; else mcp_server_agent_instances → agent_instances_accounts → agent_accounts, taking the greatest agent_accounts.last_seen_at when several match (the console's rule)",
               "mcp_server_id → mcp_servers.id", "mcp_server_type → mcp_catalog.mcp_server_type or org_mcp_catalog.mcp_server_type (product name)",
               "mcp_server_agent_instances links to the install it is configured in"],
        notes={"agent_account_id": "→ agent_accounts.id: the account a browser-connector MCP belongs to. NULL for filesystem-discovered MCPs — attribute those via mcp_server_agent_instances → agent_instances_accounts → agent_accounts (take the greatest agent_accounts.last_seen_at when several match).", "mcp_server_id": "→ mcp_servers.id (org rollup).",
               "mcp_server_type": "Integer product code; join the catalogs for the name. Not an enum.",
               "mcp_server_location": "URL for remote servers, command/path for local ones.",
               "mcp_native_id": "The server's key in the host config (mcp.json). Equals agent_events.mcp_server_name (case-insensitive).",
               "transport_type": "Transport protocol as text ('stdio' / 'http' / 'sse' / 'unknown'); never NULL, 'unknown' = unclassified.", "deployment_model": "Where the server runs, as text ('local_process' / 'local_container' / 'local_service' / 'remote' / 'unknown'); never NULL, 'unknown' = unclassified.", "auth_type": "Authentication method as text ('oauth' / 'token' / 'basic_auth' / 'no_auth' / 'unknown'); never NULL, 'unknown' = no method detected.",
               "transport_security_type": "Transport encryption as text ('none' / 'tls' / 'unknown'); never NULL, 'unknown' = unclassified.", "distribution_channel": "Who provisioned it, as text ('platform' / 'tenant' / 'user' / 'unknown'); never NULL, filesystem MCPs are 'user', 'unknown' = unmatched.", "agent_type": "Agent it is configured for.",
               "project_path": "Project/workspace path the MCP is scoped to; NULL for global-scope configs and browser connectors.", "linked_plans": "JSON array of AgentPlanType text the instance is reachable through — its direct account plus junction-linked installs (e.g. [\"personal\",\"enterprise\"]). NULL when it has neither a direct account nor an active junction link. Attribute an instance to agents as agent_type x each element: CROSS JOIN UNNEST(CAST(json_parse(linked_plans) AS array(varchar))) AS t(plan).",
               "security_findings": "JSON text; TraceForce's security observations for this instance.",
               "tools": "JSON text; tools the server exposes, as discovered on this install."}),
    "mcp_server_agent_instances": dict(
        purpose="Junction: which install (agent_instances) an MCP server instance is configured in.",
        joins=["agent_instance_id → agent_instances.id", "mcp_server_instance_id → mcp_server_instances.id",
               "No deleted_at of its own. A link is live only when BOTH parents are: agent_instances.deleted_at IS NULL AND mcp_server_instances.deleted_at IS NULL"],
        notes={"agent_instance_id": "→ agent_instances.id", "mcp_server_instance_id": "→ mcp_server_instances.id"}),
    "mcp_servers": dict(
        purpose="Org-level rollup per MCP product: counts, scores, status. One row per product per org.",
        joins=["mcp_catalog_id → mcp_catalog.id only (FK; never org_mcp_catalog.id). For private/org products resolve by mcp_server_type against both catalogs and coalesce the names",
               "mcp_server_instances.mcp_server_id = mcp_servers.id", "The console's MCP list hides rollups with active_users = 0"],
        notes={"mcp_catalog_id": "→ mcp_catalog.id (FK); NULL for products without a global catalog row", "mcp_server_type": "Product code; same as the catalogs' mcp_server_type.",
               "active_users": "MISNOMER: despite the name, the count of DISTINCT active devices running this MCP type (devices, not users); NULL when the org has none.", "total_incidents": "Count of open issue rows for this type (not deduped by type); NULL (not 0) when none are open.",
               "active_issues": "Count of distinct open issue types; NULL (not 0) when none are open.", "affected_devices": "Count of distinct devices with an open issue of this type; NULL (not 0) when none.", "base_score": "Baseline risk score (0-100) for the product; NULL (not 0) when no baseline scores exist yet.",
               "actual_score": "Risk score (0-100) from your org's usage; NULL (not 0) when no scores for this org+type yet.", "agent_names": "JSON array of agent display names with an active instance of this type; NULL when there are none.", "distribution_channels": "JSON text.",
               "auth_types": "JSON text.", "sandbox_runtime_types": "JSON text.", "instance_count": "Count of distinct active instances of this type; NULL (not 0) when none.",
               "has_host_instances": "Any instance on a host (not only sandboxes).", "first_seen_at": "First observed (UTC).", "last_reviewed": "Last reviewed (UTC)."}),
    "mcp_catalog": dict(
        purpose="Global reference: MCP products TraceForce knows.",
        joins=["mcp_catalog.mcp_server_type = mcp_server_instances.mcp_server_type", "category_id → mcp_categories.id"],
        notes={"mcp_server_name": "Product display name (Slack, Notion, Supabase, ...).", "mcp_server_type": "Product code used by instances and rollups.",
               "category_id": "→ mcp_categories.id; NULL until a category is assigned.", "source_type": "Publisher/provenance as text ('official' / 'community' / 'reference' / 'archived' / 'openai' / 'anthropic' / 'unknown'); never NULL, 'unknown' = unset.", "execution_environment": "JSON text.",
               "authentication_methods": "JSON text.", "detection_patterns": "JSON text; how TraceForce recognizes it in configs."}),
    "org_mcp_catalog": dict(
        purpose="Same shape as mcp_catalog, for private/custom MCP servers specific to your org.",
        joins=["org_mcp_catalog.mcp_server_type = mcp_server_instances.mcp_server_type", "category_id → mcp_categories.id"],
        notes={"mcp_server_name": "Product display name.", "mcp_server_type": "Product code.", "category_id": "→ mcp_categories.id; NULL until a category is assigned.", "source_type": "Publisher/provenance as text ('official' / 'community' / 'reference' / 'archived' / 'openai' / 'anthropic' / 'unknown'); never NULL, 'unknown' = unset.",
               "execution_environment": "JSON text.", "authentication_methods": "JSON text.", "detection_patterns": "JSON text."}),
    "mcp_categories": dict(
        purpose="Global reference: MCP product categories (Databases & Data Storage, OS and Local File Systems, Security Tools, ...).",
        joins=["mcp_categories.id = mcp_catalog.category_id"],
        notes={"name": "Category name.", "description": "Category description.", "resource_type": "Sensitivity class of what servers in this category reach, as text ('public' / 'internal_apps' / 'dev_tools' / 'database_infrastructure' / 'local_system')."}),
}

# ----------------------------------------------------------------------------- agent_events

# agent_events column meanings (hand-maintained; the generator asserts every column has one).
EVENT_NOTES = {
    "agent": "AGENT_IDENTITY_CLAUDE_CODE (Claude Code), AGENT_IDENTITY_CLAUDE (the claude.ai chat agent, any deployment \u2014 not the desktop app specifically), AGENT_IDENTITY_CURSOR, AGENT_IDENTITY_GITHUB_COPILOT.",
    "agent_type": "Integer code of `agent` (111, 1, 2, 8). Joins agent_catalog.agent_type and the agent_type columns of the metadata tables.",
    "device_native_id": "Device serial. Joins devices.device_native_id.",
    "device_uuid": "A stable per-install device GUID; NULL when the agent doesn't provide one. Prefer it over the serial when present.",
    "sandbox_native_id": "Sandbox identifier; will join sandboxes.sandbox_native_id. Reserved: always NULL on events today (the collector is host-only and stamps no sandbox id).",
    "path_email": "Account email associated with the source object; NULL when unknown. Independent of `user_email`.",
    "path_org": "Vendor org id associated with the source object; NULL when absent.",
    "path_session": "Session id associated with the source object; NULL when unknown.",
    "upload_ts": "When the source object was uploaded, UTC.",
    "source_object": "Storage URI of the raw object this row came from — `s3://bucket/key` on AWS, `gs://bucket/key` on GCP. Equals a finding's conversation_storage pointer (see joins.md).",
    "signal": "Whether the row is an OTLP `log` record or a `span`.",
    "user_email": "End-user email as reported by the agent; NULL when the agent reports none (fall back to the device owner for a person — see joins.md).",
    "agent_org_id": "The AI vendor's org id for the user (e.g. the Anthropic org for Claude); NULL when the agent reports none.",
    "user_id": "The AI vendor's user id; NULL when the agent reports none.",
    "session_id": "The conversation/session identifier. Joins agent_conversations.conversation_external_id. Can resolve to a window-level fallback rather than a true conversation id (see resource_session_id).",
    "resource_session_id": "A resource-level session id that may be coarser than one conversation (e.g. one per editor window). `session_id` falls back to it; compare the two to tell a real conversation id from a window-level fallback.",
    "ts": "Event time, UTC.",
    "end_ts": "Span end time, UTC; NULL on logs.",
    "event_name": "Agent-specific event name (user_prompt, tool_decision, tool_result, api_request, api_error, preToolUse, ...). Vocabularies differ per agent.",
    "span_name": "Span name (spans only).",
    "operation": "Operation type per GenAI semconv (`chat`, `execute_tool`, `invoke_agent`); the cross-agent grouping key. NULL on non-GenAI rows (e.g. connection/session-lifecycle events).",
    "prompt_id": "Per-turn (request/response) identifier; NULL when the agent emits none. Count distinct to count prompts.",
    "generation_id": "Per-turn identifier emitted by agents that use a separate generation id, distinct from `prompt_id`; NULL otherwise.",
    "tool_name": "The tool invoked. MCP tool calls surface as `mcp_tool` with the server in `mcp_server_name`.",
    "tool_type": "Tool type (function, ...).",
    "tool_call_id": "Per-call id; equals connector_containment_findings.tool_use_id (join key). NULL when the agent emits none. Repeats across the decision/result/span rows of one call, so it is not unique.",
    "mcp_server_name": "MCP server as configured on the device; joins lower(mcp_server_instances.mcp_native_id).",
    "tool_args": "Tool input, JSON text; occasionally plain text (e.g. a raw shell command). Large.",
    "tool_result": "Tool output; NULL when the agent doesn't emit it. Large.",
    "decision": "Permission decision as the agent recorded it (e.g. `accept`/`reject`, `approved`/`denied-interactively-by-user`); NULL when the agent records none.",
    "sd_enforcement": "TraceForce sensitive-data policy mode in force on the prompt (`warn` or `block`), not the outcome; NULL when no policy applied.",
    "containment_enforcement": "TraceForce containment policy mode in force on the tool call (`warn` or `block`), not the outcome; NULL when no policy applied.",
    "error_type": "Error class/type on error rows (e.g. `permission_denied`, `403`); NULL otherwise.",
    "model": "The model requested for the turn.",
    "input_tokens": "Input tokens for the request; NULL when the agent reports no token counts.",
    "output_tokens": "Output tokens for the request; NULL when the agent reports no token counts.",
    "cache_read_tokens": "Cache-read tokens for the request; NULL when the agent reports no token counts.",
    "cost_usd": "Turn cost in USD as reported by the agent; NULL when the agent reports none.",
    "content_input": "Prompt as a JSON message array; masked per matched value when the org redacts. Large.",
    "content_output": "Response as a JSON message array; masked per matched value when the org redacts. Large.",
    "service_name": "The emitting service's name (OTLP resource attribute); may name the collector rather than the agent.",
    "service_version": "Version string of the emitter — the agent, or the collector when it emits on the agent's behalf.",
    "os_type": "Operating system of the device; NULL when not reported.",
    "attrs_json": "Every other record attribute as JSON text: json_extract_scalar(attrs_json, '$[\"cursor.version\"]'). The decision source lives here: $.source.",
    "resource_json": "Every resource attribute as JSON text.",
    "ingested_at": "When the row was loaded, UTC.",
}

# ----------------------------------------------------------------------------- parse terraform
def parse_export_tables(text):
    body = text[text.index("export_tables = {"):]
    body = body[: body.index("\n  }\n")]
    out, cur = {}, None
    for line in body.splitlines():
        m = re.match(r"\s{4}(\w+) = \[", line)
        if m:
            cur = m.group(1); out[cur] = []; continue
        if cur:
            out[cur] += [tuple(c.split(":", 1)) for c in re.findall(r'"([^"]+)"', line)]
    quoted = len(re.findall(r'"[^"]+"', body))
    parsed = sum(len(v) for v in out.values())
    assert quoted == parsed, f"parsed {parsed} of {quoted} column entries"
    return out

def parse_agent_events(text):
    return re.findall(r'\{ name = "(\w+)", type = "(\w+)", required = (true|false) \}', text)

def main():
    exports = parse_export_tables((TF / "exports.tf").read_text())
    events = parse_agent_events((TF / "s3tables.tf").read_text())
    assert events, "no agent_events columns parsed from s3tables.tf"
    missing = [t for t in exports if t not in TABLES]
    if missing:
        print("ERROR: no notes for", missing, file=sys.stderr); sys.exit(1)
    blank = [(t, c) for t, cols in exports.items() for c, _ in cols
             if not (TABLES[t]["notes"].get(c) or COMMON.get(c))]
    if blank:
        print("ERROR: columns without a meaning:", blank, file=sys.stderr); sys.exit(1)
    OUT.mkdir(parents=True, exist_ok=True)

    lines = ["# TraceForce metadata tables", "",
             "Daily snapshots of TraceForce's control plane for this org, in the `traceforce` namespace next to `agent_events`.",
             "Types are Iceberg types; every id is a uuid stored as text; timestamps are UTC; `jsonb`/array columns are JSON text",
             "(`json_extract_scalar(col, '$.key')`). Soft deletes use `deleted_at`. Enum columns are already",
             "human-readable text (e.g. `op` = 'delete', `category` = 'credentials', `finding_status` = 'awaiting_review');",
             "the only integer codes left are the join keys `agent_type` and `mcp_server_type` (resolve via the catalogs).",
             "Generated by tools/gen_skill_reference.py from terraform/aws/exports.tf; do not edit by hand.", ""]
    tdir = OUT / "tables"; tdir.mkdir(exist_ok=True)
    for old in tdir.glob("*.md"):
        old.unlink()
    lines += ["One file per table under `tables/`; read only the ones a question needs.", "",
              "| table | purpose | file |", "|---|---|---|"]
    for t, cols in exports.items():
        meta = TABLES[t]
        lines.append(f"| `{t}` | {meta['purpose'].split('. ')[0].rstrip('.')} | `tables/{t}.md` |")
        body = [f"# {t}", "", meta["purpose"], ""]
        if meta["joins"]:
            body += ["Joins:"] + [f"- {j}" for j in meta["joins"]] + [""]
        if UNIQUE.get(t):
            body += ["Unique in the source (Iceberg does not enforce it; the mirror is keyed by `id`):"] + [f"- {u}" for u in UNIQUE[t]] + [""]
        body += ["| column | type | meaning |", "|---|---|---|"]
        for name, typ in cols:
            note = meta["notes"].get(name) or COMMON.get(name, "")
            body.append(f"| `{name}` | {typ} | {note} |")
        body.append("")
        (tdir / f"{t}.md").write_text("\n".join(body))
    lines.append("")
    (OUT / "tables.md").write_text("\n".join(lines))

    a = ["# agent_events", "", "One row per OTLP log record or span, flattened from the raw activity objects in your bucket.",
         "Types are Iceberg types; timestamps UTC. Generated by tools/gen_skill_reference.py.", "",
         "No key: a session has many rows, a tool call has 2-3 rows (decision, result, span). Count distinct `session_id`,",
         "`tool_call_id` or `prompt_id` rather than rows when the question is about sessions, calls or prompts.", "",
         "| column | type | meaning |", "|---|---|---|"]
    unknown = [n for n, _, _ in events if n not in EVENT_NOTES]
    assert not unknown, f"agent_events columns without a meaning: {unknown}"
    a += [f"| `{n}` | {t} | {EVENT_NOTES[n]} |" for n, t, r in events]
    a.append("")
    (OUT / "agent_events.md").write_text("\n".join(a))
    for stale in ("agent_events_columns.md", "enums.md"):
        if (OUT / stale).exists():
            (OUT / stale).unlink()

    print(f"tables.md index + tables/*.md: {len(exports)} tables; agent_events.md: {len(events)} columns")

if __name__ == "__main__":
    main()
