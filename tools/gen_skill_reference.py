#!/usr/bin/env python3
"""Generate the skill's schema reference from the Terraform column lists.

Single source of truth for column names/types is terraform/ (exports.tf for the mirrors,
s3tables.tf for agent_events). This script adds meaning: per-column notes, enum
decodings (from TraceForce's public enums and API vocabulary) and join
rules, and writes skills/traceforce-lakehouse/reference/*.md. Re-run after changing
either .tf file; commit the output.
"""
import re, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
TF = ROOT / "terraform"
OUT = ROOT / "skills" / "traceforce-lakehouse" / "reference"

# ----------------------------------------------------------------------------- enums
ENUMS = {
    "AgentIdentity (lake agents)": {1: "Claude (the claude.ai chat agent \u2014 any deployment; distinct from Claude Code, 111)", 2: "Cursor", 8: "GitHub Copilot", 111: "Claude Code",
                                    "…": "every other value: join agent_catalog on agent_type for the name"},
    "AgentPlanType": {0: "unspecified", 1: "personal", 2: "enterprise", 3: "small_business"},
    "AgentDeploymentType": {0: "unknown", 1: "desktop_app", 2: "vscode_extension", 3: "cli", 4: "browser", 5: "ai_browser", 6: "service"},
    "SensitiveDataCategory": {0: "unknown", 1: "credentials", 2: "identity_financial_pii", 3: "contact_pii"},
    "SensitiveDataType": {0: "unknown", 1: "api_key", 2: "private_key", 3: "password", 4: "database_connection_string",
                          100: "ssn", 101: "credit_card", 102: "bank_account_number", 103: "government_id",
                          200: "email_address", 201: "phone_number", 202: "physical_address"},
    "FindingStatus": {0: "unknown", 1: "awaiting_review", 2: "under_review", 3: "false_positive", 4: "revoked",
                      5: "used_in_tests", 6: "wont_fix", 7: "acknowledged"},
    "ContainmentOp": {0: "unknown", 1: "write", 2: "delete"},
    "OperationOutcome": {0: "unspecified", 1: "executed", 2: "failed", 3: "denied (never stored: denied events are dropped before the table)"},
    "MCPTransportType": {0: "unknown", 1: "stdio", 2: "http", 3: "sse"},
    "TransportSecurityType": {0: "unknown", 1: "none", 2: "tls"},
    "MCPDeploymentModel": {0: "unknown", 1: "local_process", 2: "local_container", 3: "local_service", 4: "remote"},
    "IdentityControlType (auth_type)": {0: "unknown", 1: "basic_auth", 2: "token", 3: "oauth", 4: "no_auth"},
    "MCPDistributionChannel": {0: "unknown", 1: "platform (managed_by=admin)", 2: "tenant (managed_by=admin)", 3: "user (managed_by=user)"},
    "MCPSourceType": {0: "unknown", 1: "official", 2: "community", 3: "reference", 4: "archived", 5: "openai", 6: "anthropic"},
    "MCP category resource_type (IssueDetail subset)": {10120: "public", 10121: "internal_apps", 10122: "dev_tools", 10123: "database_infrastructure", 10124: "local_system"},
    "SandboxRuntimeType": {0: "unspecified", 1: "devcontainer"},
}
COLUMN_ENUMS = {
    ("agent_accounts", "agent_type"): "AgentIdentity (lake agents)",
    ("agent_instances", "agent_type"): "AgentIdentity (lake agents)",
    ("mcp_server_instances", "agent_type"): "AgentIdentity (lake agents)",
    ("agent_catalog", "agent_type"): "AgentIdentity (lake agents)",
    ("agent_accounts", "plan"): "AgentPlanType",
    ("agent_instances", "agent_deployment"): "AgentDeploymentType",
    ("sensitive_data_findings", "category"): "SensitiveDataCategory",
    ("sensitive_data_findings", "type"): "SensitiveDataType",
    ("sensitive_data_findings", "finding_status"): "FindingStatus",
    ("connector_containment_findings", "op"): "ContainmentOp",
    ("connector_containment_findings", "outcome"): "OperationOutcome",
    ("connector_containment_findings", "finding_status"): "FindingStatus",
    ("mcp_server_instances", "transport_type"): "MCPTransportType",
    ("mcp_server_instances", "transport_security_type"): "TransportSecurityType",
    ("mcp_server_instances", "deployment_model"): "MCPDeploymentModel",
    ("mcp_server_instances", "auth_type"): "IdentityControlType (auth_type)",
    ("mcp_server_instances", "distribution_channel"): "MCPDistributionChannel",
    ("mcp_catalog", "source_type"): "MCPSourceType",
    ("org_mcp_catalog", "source_type"): "MCPSourceType",
    ("mcp_categories", "resource_type"): "MCP category resource_type (IssueDetail subset)",
    ("sandboxes", "runtime_type"): "SandboxRuntimeType",
}

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
    "customer_storage": "JSON text {bucket, key_prefix, region, provider, source_file}. On conversations source_file is the session FOLDER (conversations/<agent>/dt=<YYYYMMDD>/<serial>/<account>/<session>/ for collector 1.0.42+, no dt= segment before; a session spanning midnight has two). On findings it is the EVIDENCE object under findings/<agent>/<serial>/<account>/<session>/evidence/ (verbatim matched value / verbatim tool input; for file findings the redacted attachment). Evidence is NOT in the lake by design; see SKILL.md Redaction and evidence.",
    "conversation_storage": "JSON text {bucket, key_prefix, region, provider, source_file}: the exact activity object the finding was detected in. Equals agent_events.source_object when written as concat('s3://', bucket, '/', key_prefix, source_file); join on it to get the records of that upload.",
    "description": "Catalog description.",
    "website": "Vendor website.",
    "logo_url": "Logo URL.",
}
TABLES = {
    "devices": dict(
        purpose="One row per device TraceForce has seen (laptops, workstations). The anchor for every join from the logs.",
        joins=["agent_events.device_uuid = devices.device_uuid when the event has one (Windows), else agent_events.device_native_id = devices.device_native_id"],
        notes={"device_native_id": "OS-reported serial (e.g. C02XXXXXXXXX on macOS). Same value as agent_events.device_native_id. Windows serials can be placeholders shared by many machines.",
               "device_uuid": "Windows per-install GUID; NULL on macOS/Linux. Prefer it over the serial when present. agent_events.device_uuid is NULL on every row until the collector release that stamps it ships, so today the device join degenerates to the serial.",
               "friendly_name": "Human-readable name (e.g. Jane's MacBook Pro).", "platform": "darwin / windows / linux.",
               "architecture": "CPU architecture (arm64, x86_64).", "os_version": "OS version string.", "chip_model": "Chip model when reported.",
               "account_metadata": "JSON text keyed by OS uid/SID with the OS username; how agent_instances.tenant resolves to a username."}),
    "sandboxes": dict(
        purpose="Devcontainers / cloud VMs an agent ran in. The parent host is a row in devices.",
        joins=["sandboxes.parent_device_id = devices.id", "agent_events.sandbox_native_id = sandboxes.sandbox_native_id (reserved; NULL in events today)"],
        notes={"parent_device_id": "→ devices.id of the host.", "sandbox_native_id": "Sandbox identifier as the collector will stamp it.",
               "runtime_type": "Sandbox runtime.", "workspace_folder": "Workspace path inside the sandbox.", "friendly_name": "Display name.",
               "os_version": "Guest OS version.", "account_metadata": "JSON text; OS users inside the sandbox."}),
    "agent_accounts": dict(
        purpose="One row per signed-in account: (device, agent, email, vendor org). Who is behind an event.",
        joins=["agent_accounts.device_id = devices.id AND agent_accounts.agent_type = agent_events.agent_type AND lower(agent_accounts.agent_email) = lower(agent_events.user_email) (enrichment of an event with plan / vendor org; the person is already user_email)",
               "agent_accounts.agent_org_id = agent_events.agent_org_id when both are non-NULL (Claude family)",
               "When reached by id from agent_conversations.agent_account_id, do NOT filter deleted_at: a signed-out account still owns its past findings (this is what the console does)"],
        notes={"agent_type": "Which agent product.", "plan": "Account plan. The console's notion of an agent is an INSTALL's (agent_type, coalesce(plan, 0)): start from agent_instances, LEFT JOIN agent_instances_accounts and agent_accounts; installs with no signed-in account are plan 0. Never count agents from agent_accounts alone.", "tier": "Vendor plan tier text when known.",
               "agent_email": "Email the user authenticated to the agent with. Stored byte-exact; lower() is a tolerance.",
               "agent_org_id": "The vendor's workspace/org id (Anthropic org for Claude); NULL for Cursor/Copilot.",
               "agent_id": "→ the org-level agent rollup (not exported in v1).",
               "security_settings": "JSON text; vendor security settings observed for the account.",
               "models_configuration": "JSON text; models configured for the account."}),
    "agent_instances": dict(
        purpose="Installs: one row per (device, agent, deployment form factor, OS user). Includes agents that never produce an account (Copilot).",
        joins=["agent_instances.device_id = devices.id AND agent_instances.agent_type = agent_events.agent_type",
               "agent_instances_accounts links an install to the accounts signed in through it"],
        notes={"agent_type": "Which agent product.", "agent_deployment": "Form factor of this install.",
               "tenant": "OS-level user (uid on macOS/Linux, SID on Windows) the install belongs to; resolve to a username via devices.account_metadata.",
               "agent_catalog_id": "→ agent_catalog.id", "configuration": "JSON text; detected agent configuration.",
               "installations": "JSON text; filesystem installation records (paths, versions)."}),
    "agent_instances_accounts": dict(
        purpose="Junction: which account is signed in through which install.",
        joins=["agent_instance_id → agent_instances.id", "agent_account_id → agent_accounts.id",
               "No deleted_at of its own. A link is live only when BOTH parents are: agent_instances.deleted_at IS NULL AND agent_accounts.deleted_at IS NULL (the console's active_agent_instances_accounts view)"],
        notes={"agent_instance_id": "→ agent_instances.id", "agent_account_id": "→ agent_accounts.id"}),
    "device_owner_mappings": dict(
        purpose="Device owner from your MDM. The attribution path for agents whose logs carry no email (Copilot, Vertex-authenticated Claude Code).",
        joins=["device_owner_mappings.device_native_id = agent_events.device_native_id (or = devices.device_native_id)"],
        notes={"mdm_integration_id": "Which MDM integration produced the mapping.", "device_native_id": "Serial as reported by the MDM.",
               "owner_email": "Owner email from the MDM.", "owner_name": "Owner display name from the MDM."}),
    "agent_catalog": dict(
        purpose="Global reference: agent_type → product name, one row per known agent type.",
        joins=["agent_catalog.agent_type = agent_instances.agent_type (or agent_accounts / agent_events.agent_type)"],
        notes={"agent_name": "Display name (Claude Code, Cursor, GitHub Copilot, ChatGPT, ...).", "agent_type": "The integer code used everywhere else.",
               "domain": "Vendor domain."}),
    "sensitive_data_findings": dict(
        purpose="One row per sensitive-data match (a credential, PII value, ...) found in a prompt/response or an attached file. Most findings come from attached files rather than prompt text; always handle both paths (file_id NULL = message finding).",
        joins=["person: conversation_id → agent_conversations.agent_account_id → agent_accounts.agent_email (NOT NULL; every finding has one). Do NOT filter agent_accounts.deleted_at here: findings on since-removed accounts still belong to that person. agent_type → agent_catalog for the agent name",
               "device owner (secondary, for display): device_id → devices.device_native_id → device_owner_mappings.owner_email",
               "conversation_id → agent_conversations.id → conversation_external_id = agent_events.session_id",
               "file_id → agent_conversation_files.id (file name, type, size)",
               "conversation_storage pointer → agent_events.source_object (the exact uploaded object the match was found in)"],
        notes={"conversation_id": "→ agent_conversations.id (TraceForce uuid, NOT the agent's session id).",
               "file_id": "→ agent_conversation_files.id when the match is in an attachment; NULL for message findings.",
               "message_external_id": "The agent's own id of the source message (Claude prompt/response id, Cursor generation id).",
               "message_timestamp": "When the message was sent (UTC): the column to bound a period on; created_at is when TraceForce recorded it.", "category": "Coarse class of the match.", "type": "Exact data type of the match.",
               "start_offset": "Character offset of the match start within the scanned text.", "end_offset": "Character offset of the match end (exclusive).",
               "start_line": "0-indexed first line of the match within the scanned text (message or attachment). Not a message/file discriminator: use file_id IS NULL for message findings.", "end_line": "0-indexed last line (inclusive).",
               "part_index": "Index of the message part the match is in.", "rule_id": "Detector rule that fired.",
               "encoding_type": "Set when the value was encoded (e.g. base64) and decoded before matching.",
               "archive_inner_path": "Path inside a zip/tar when the finding is in an archive entry.",
               "finding_status": "Reviewer triage state; open = IN (1, 2) as the API counts it. Not the enforcement outcome: see SKILL.md, Enforcement outcomes (a blocked prompt never produces a finding row)."}),
    "connector_containment_findings": dict(
        purpose="One row per write/delete a tool attempted through a connector (MCP, Bash, Write). Denied attempts are NOT stored; only executed/failed ones.",
        joins=["person: conversation_id → agent_conversations.agent_account_id → agent_accounts (no deleted_at filter); device owner via device_id → devices → device_owner_mappings",
               "tool_use_id = agent_events.tool_call_id (same session). Claude family only: Cursor emits no tool_decision, read the finding's own outcome and the postToolUseFailure row with the same tool_call_id",
               "conversation_id → agent_conversations.id → agent_events.session_id", "device_id → devices.id",
               "conversation_storage pointer → agent_events.source_object (the exact uploaded object)"],
        notes={"conversation_id": "→ agent_conversations.id", "op": "Kind of mutation attempted.", "tool_name": "Tool that attempted it (Write, Bash, MCP:<server>).",
               "operation": "The MCP tool name (e.g. execute_sql) or the risky statement; empty for non-MCP tools.",
               "tool_use_id": "Agent's tool-call id; equals agent_events.tool_call_id.", "prompt_id": "Hook prompt id; NULL on all rows today (known gap).",
               "hook_event_name": "Hook that observed it (e.g. PreToolUse).", "detected_at": "When detected (UTC).",
               "finding_status": "Reviewer triage state.", "outcome": "Execution result. Never 'denied' in the table."}),
    "agent_conversations": dict(
        purpose="One row per agent session/conversation TraceForce has scanned; created on scan whether or not anything was found (most rows have no finding). The bridge between findings and the logs; count findings from the findings tables, not from here.",
        joins=["agent_conversations.conversation_external_id = agent_events.session_id", "agent_account_id → agent_accounts.id", "device_id → devices.id",
               "customer_storage.source_file is the session folder: agent_events.source_object LIKE concat('s3://', bucket, '/', key_prefix, source_file, '%')"],
        notes={"agent_account_id": "→ agent_accounts.id", "conversation_external_id": "The agent's session/conversation id; equals agent_events.session_id.",
               "name": "Conversation title as shown in the agent UI; NULL if untitled.", "is_archived": "Archived in the agent UI.",
               "conversation_create_time": "Agent-reported creation time (UTC).", "conversation_update_time": "Agent-reported last update (UTC)."}),
    "agent_conversation_files": dict(
        purpose="Files attached to conversations (uploads). What a file finding points at.",
        joins=["agent_conversation_files.id = sensitive_data_findings.file_id", "conversation_id → agent_conversations.id"],
        notes={"conversation_id": "→ agent_conversations.id", "file_external_id": "Agent's own file id.", "file_name": "Original filename.",
               "mime_type": "MIME type.", "size_bytes": "Size in bytes.", "message_external_id": "Agent's id of the message the file was attached to.",
               "message_timestamp": "When it was attached (UTC).", "archive_inner_path": "Entry path when the file is an archive member."}),
    "mcp_server_instances": dict(
        purpose="MCP servers configured on a device for an agent. The MCP inventory; the name matches what the logs carry.",
        joins=["lower(mcp_server_instances.mcp_native_id) = lower(agent_events.mcp_server_name) AND same device_id/agent_type. Not a key: the same server name can have several live rows per device (one per project_path or location), so aggregate or SELECT DISTINCT",
               "account: agent_account_id when set; else mcp_server_agent_instances → agent_instances_accounts → agent_accounts, taking the greatest agent_accounts.last_seen_at when several match (the console's rule)",
               "mcp_server_id → mcp_servers.id", "mcp_server_type → mcp_catalog.mcp_server_type or org_mcp_catalog.mcp_server_type (product name)",
               "mcp_server_agent_instances links to the install it is configured in"],
        notes={"agent_account_id": "→ agent_accounts.id. Set for account-scoped agents (Claude = 1, ChatGPT = 3); NULL for Claude Code (111) and Cursor (2), whose MCP inventory is device-scoped: resolve those through device_id or the junction tables.", "mcp_server_id": "→ mcp_servers.id (org rollup).",
               "mcp_server_type": "Integer product code; join the catalogs for the name. Not an enum.",
               "mcp_server_location": "URL for remote servers, command/path for local ones.",
               "mcp_native_id": "The server's key in the host config (mcp.json). Equals agent_events.mcp_server_name (case-insensitive).",
               "transport_type": "Transport protocol.", "deployment_model": "Where the server runs.", "auth_type": "Authentication method.",
               "transport_security_type": "TLS or none.", "distribution_channel": "Who installed it (admin vs user).", "agent_type": "Agent it is configured for.",
               "project_path": "Project/workspace path that configured it; NULL for global config.", "linked_plans": "JSON array of AgentPlanType codes (e.g. [2,3]) derived from the accounts signed in through this install; [0] = no signed-in account. The console attributes an MCP instance to agents as agent_type x each element: CROSS JOIN UNNEST(CAST(json_parse(linked_plans) AS array(integer))) AS t(plan).",
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
               "mcp_server_status": "TraceForce internal lifecycle code.", "active_users": "Users seen using it.", "total_incidents": "Incidents raised.",
               "active_issues": "Open issues.", "affected_devices": "Devices with an instance.", "base_score": "Baseline risk score 0-100 for the product.",
               "actual_score": "Risk score 0-100 from your org's usage.", "agent_names": "JSON text; agents using it.", "distribution_channels": "JSON text.",
               "auth_types": "JSON text.", "sandbox_runtime_types": "JSON text.", "instance_count": "Number of instances.",
               "has_host_instances": "Any instance on a host (not only sandboxes).", "first_seen_at": "First observed (UTC).", "last_reviewed": "Last reviewed (UTC)."}),
    "mcp_catalog": dict(
        purpose="Global reference: MCP products TraceForce knows.",
        joins=["mcp_catalog.mcp_server_type = mcp_server_instances.mcp_server_type", "category_id → mcp_categories.id"],
        notes={"mcp_server_name": "Product display name (Slack, Notion, Supabase, ...).", "mcp_server_type": "Product code used by instances and rollups.",
               "category_id": "→ mcp_categories.id", "source_type": "Who publishes it.", "execution_environment": "JSON text.",
               "authentication_methods": "JSON text.", "detection_patterns": "JSON text; how TraceForce recognizes it in configs."}),
    "org_mcp_catalog": dict(
        purpose="Same shape as mcp_catalog, for private/custom MCP servers specific to your org.",
        joins=["org_mcp_catalog.mcp_server_type = mcp_server_instances.mcp_server_type", "category_id → mcp_categories.id"],
        notes={"mcp_server_name": "Product display name.", "mcp_server_type": "Product code.", "category_id": "→ mcp_categories.id", "source_type": "Who publishes it.",
               "execution_environment": "JSON text.", "authentication_methods": "JSON text.", "detection_patterns": "JSON text."}),
    "mcp_categories": dict(
        purpose="Global reference: MCP product categories (Databases & Data Storage, OS and Local File Systems, Security Tools, ...).",
        joins=["mcp_categories.id = mcp_catalog.category_id"],
        notes={"name": "Category name.", "description": "Category description.", "resource_type": "Sensitivity class of what servers in this category reach."}),
}

# ----------------------------------------------------------------------------- agent_events

# agent_events column meanings (hand-maintained; the generator asserts every column has one).
EVENT_NOTES = {
    "agent": "AGENT_IDENTITY_CLAUDE_CODE (Claude Code), AGENT_IDENTITY_CLAUDE (the claude.ai chat agent, any deployment \u2014 not the desktop app specifically), AGENT_IDENTITY_CURSOR, AGENT_IDENTITY_GITHUB_COPILOT.",
    "agent_type": "Integer code of `agent` (111, 1, 2, 8). Joins agent_catalog.agent_type and the agent_type columns of the metadata tables.",
    "device_native_id": "Device serial. Joins devices.device_native_id.",
    "device_uuid": "Windows per-install GUID; NULL elsewhere. Prefer it over the serial when present. NULL on every row until the collector release that stamps it ships.",
    "sandbox_native_id": "Reserved; NULL today. Will join sandboxes.sandbox_native_id.",
    "path_email": "Account segment of the object path (email as the collector saw it); NULL when unknown.",
    "path_org": "Vendor org id from the object path when present.",
    "path_session": "Session segment of the object path; NULL when unknown.",
    "upload_ts": "When the object was uploaded (from its filename), UTC.",
    "source_object": "s3://bucket/key of the raw object this row came from. Equals a finding's conversation_storage pointer (see joins.md).",
    "signal": "log or span. Claude Code emits both; Copilot only spans.",
    "user_email": "As emitted by the agent. Claude Code/Cowork/Cursor; NULL for Copilot and for Vertex-authenticated Claude Code.",
    "agent_org_id": "The AI vendor's org id (Anthropic org for Claude); NULL for Cursor/Copilot.",
    "user_id": "Vendor user id (Claude family only).",
    "session_id": "The conversation/session: gen_ai.conversation.id, else record session.id, else resource session.id, else the path. Joins agent_conversations.conversation_external_id.",
    "resource_session_id": "The OTLP resource-level session.id (Copilot: one per VS Code window). session_id falls back to it; compare the two to tell a real conversation id from a window-level fallback.",
    "ts": "Event time, UTC. Record time, else observed time, else upload time.",
    "end_ts": "Span end time, UTC; NULL on logs.",
    "event_name": "Agent-specific event name (user_prompt, tool_decision, tool_result, api_request, api_error, preToolUse, ...). Vocabularies differ per agent.",
    "span_name": "Span name (spans only).",
    "operation": "chat, execute_tool, invoke_agent (GenAI semconv), all agents except Claude-family mcp_server_connection and Cursor sessionStart/sessionEnd rows. The cross-agent grouping key.",
    "prompt_id": "Per-turn id (Claude family).",
    "generation_id": "Per-turn id (Cursor).",
    "tool_name": "Tool identity, all agents. MCP tool calls appear as mcp_tool with mcp_server_name set (Claude family) or with the server name in mcp_server_name (Copilot).",
    "tool_type": "Tool type (function, ...).",
    "tool_call_id": "Per-call id; equals connector_containment_findings.tool_use_id. Present on Claude family and Copilot; Cursor's synthesized shell/read/edit records have none. Repeats within a session (decision, result, span rows), never a key.",
    "mcp_server_name": "MCP server as configured on the device; joins lower(mcp_server_instances.mcp_native_id).",
    "tool_args": "Tool input as JSON text (Cursor shell records: plain command text). Large.",
    "tool_result": "Tool output (Claude Code spans, Cursor, Copilot); Cowork never carries it. Large.",
    "decision": "Permission decision as the agent recorded it: accept/reject (Claude family), approved/denied-interactively-by-user (Copilot). NULL on Cursor rows.",
    "sd_enforcement": "TraceForce sensitive-data policy MODE in force on the prompt (warn/block), not the outcome. Claude Code only.",
    "containment_enforcement": "TraceForce containment policy MODE in force on the tool call, not the outcome. Claude Code and Cursor.",
    "error_type": "Error class (error.type / error_type / permission_denied / 403 ...).",
    "model": "Model requested (gen_ai.request.model).",
    "input_tokens": "Input tokens (Claude family, Copilot). NULL for Cursor.",
    "output_tokens": "Output tokens (Claude family, Copilot). NULL for Cursor.",
    "cache_read_tokens": "Cache-read tokens (Claude family, Copilot).",
    "cost_usd": "Cost as reported by the agent (Claude family only; Copilot and Cursor emit none).",
    "content_input": "Prompt as a JSON message array; masked per matched value when the org redacts. Large.",
    "content_output": "Response as a JSON message array; masked per matched value when the org redacts. Large.",
    "service_name": "Emitter service name (Cursor rows name the TraceForce collector).",
    "service_version": "Agent version (Claude family, Copilot) or collector version (Cursor).",
    "os_type": "OS from the resource attributes (Claude family only).",
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
             "(`json_extract_scalar(col, '$.key')`). Soft deletes use `deleted_at`. Integer codes are decoded in `enums.md`.",
             "Generated by tools/gen_skill_reference.py from terraform/exports.tf; do not edit by hand.", ""]
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
            enum = COLUMN_ENUMS.get((t, name))
            if enum:
                note = (note + " " if note else "") + f"Codes: `{enum}` in ../enums.md."
            body.append(f"| `{name}` | {typ} | {note} |")
        body.append("")
        (tdir / f"{t}.md").write_text("\n".join(body))
    lines.append("")
    (OUT / "tables.md").write_text("\n".join(lines))

    e = ["# Integer codes", "", "Decode integer columns with these tables (from TraceForce's proto and public API vocabulary).", "",
         "Contents: " + ", ".join(ENUMS.keys()) + ".", ""]
    for name, vals in ENUMS.items():
        e += [f"## {name}", "", "| code | meaning |", "|---|---|"]
        e += [f"| {k} | {v} |" for k, v in vals.items()]
        if name == "FindingStatus":
            e.append("\nOpen, as the API's open_count uses it, is finding_status IN (1, 2) on both findings tables; every other value, including 0 (unknown) and 7 (acknowledged), counts as closed.")
        e.append("")
    e += ["## Not enumerated", "", "- `mcp_server_type` (instances, rollups, catalogs): a product code, join `mcp_catalog` / `org_mcp_catalog` for the name.",
          "- `mcp_servers.mcp_server_status`: TraceForce internal lifecycle code.", ""]
    (OUT / "enums.md").write_text("\n".join(e))

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
    for stale in ("agent_events_columns.md",):
        if (OUT / stale).exists():
            (OUT / stale).unlink()

    print(f"tables.md index + tables/*.md: {len(exports)} tables; enums.md: {len(ENUMS)} enums; agent_events.md: {len(events)} columns")

if __name__ == "__main__":
    main()
