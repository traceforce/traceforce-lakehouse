# Join patterns that are not obvious from the schema

These are starting points, not templates. Take only the join or attribution rule you need. If
none matches the question's shape, write the query from the table files. Do not carry over a
filter, time window or extra column because an example has it.

## Event to person

Use when a result should be per person. Email on the event when the agent emitted one,
otherwise the MDM owner of the device. Copilot and Vertex-authenticated Claude Code never
carry an email, so without this fallback they vanish from per-person answers.

```sql
SELECT coalesce(lower(e.user_email), lower(m.owner_email)) AS person, ...
FROM agent_events e
LEFT JOIN device_owner_mappings m ON m.device_native_id = e.device_native_id
```

## Finding to its person, and to the events around it

Use when starting from a finding. The person is the conversation's account, by id, with no
`deleted_at` filter (a signed-out account still owns its past findings). The events are the
agent's session, bridged through `agent_conversations`, then windowed on time.

```sql
WITH f AS (
  SELECT c.conversation_external_id AS session_id, sf.message_timestamp AS at, a.agent_email
  FROM sensitive_data_findings sf
  JOIN agent_conversations c ON c.id = sf.conversation_id
  JOIN agent_accounts a ON a.id = c.agent_account_id
  WHERE sf.id = '<finding id>'
)
SELECT e.ts, e.event_name, e.operation, e.tool_name, e.decision, substr(e.content_input, 1, 300) AS input_preview
FROM agent_events e JOIN f ON e.session_id = f.session_id
WHERE e.ts BETWEEN f.at - interval '10' minute AND f.at + interval '10' minute
  AND (e.user_email IS NULL OR lower(e.user_email) = lower(f.agent_email)) -- the same session id can exist under two accounts
ORDER BY e.ts
```

## Containment finding to the decision that approved it

Use when asking how a write or delete was approved. `tool_use_id` on the finding equals
`tool_call_id` on the events of the same session, and the `tool_decision` row carries the
source. Claude family only: Cursor emits no `tool_decision`, so for Cursor read the finding's
own `outcome` and, for a failed write, the `postToolUseFailure` row with the same
`tool_call_id`. On rows that reached the findings table, `source = 'hook'` means the user's own
PreToolUse hook approved (TraceForce's hook never returns allow); `config` means Claude's own
permission rules; `user_*` means a person clicked. Denied attempts never reach this table;
they are `decision = 'reject'` events only.

```sql
SELECT f.detected_at, f.tool_name, f.operation, e.decision,
       json_extract_scalar(e.attrs_json, '$.source') AS decision_source
FROM connector_containment_findings f
JOIN agent_conversations c ON c.id = f.conversation_id
LEFT JOIN agent_events e ON e.session_id = c.conversation_external_id
                        AND e.tool_call_id = f.tool_use_id AND e.event_name = 'tool_decision'
```

## Installed MCP servers to their actual use

Use when comparing inventory with usage. Inventory is per (device, agent); usage in the logs
is per (device serial, agent type, server name), matched case-insensitively. The same server
name can have several live inventory rows per device (one per project path or location), so
aggregate the inventory side or the counts multiply. `LEFT JOIN` so a NULL count means
installed and never called. The `calls` side is per serial: a Windows placeholder serial
shared by several devices repeats its count on each of them (see Identity rules). Product name and category come through `mcp_server_type` against
both catalogs, never through `mcp_servers.mcp_catalog_id` for org-private servers.

```sql
WITH calls AS (
  SELECT device_native_id, agent_type, lower(mcp_server_name) AS name_lc, count(*) AS calls, max(ts) AS last_call
  FROM agent_events WHERE mcp_server_name IS NOT NULL AND ts > current_timestamp - interval '30' day GROUP BY 1, 2, 3
),
inventory AS (
  SELECT i.device_id, i.agent_type, lower(i.mcp_native_id) AS name_lc, i.mcp_server_type,
         min(i.auth_type) AS auth_type, count(*) AS configs
  FROM mcp_server_instances i WHERE i.deleted_at IS NULL GROUP BY 1, 2, 3, 4
)
SELECT d.device_native_id, inv.name_lc AS server, coalesce(mc.mcp_server_name, omc.mcp_server_name) AS product,
       cat.name AS category, inv.auth_type, inv.configs, c.calls, c.last_call
FROM inventory inv
JOIN devices d ON d.id = inv.device_id
LEFT JOIN mcp_catalog mc ON mc.mcp_server_type = inv.mcp_server_type
LEFT JOIN org_mcp_catalog omc ON omc.mcp_server_type = inv.mcp_server_type
LEFT JOIN mcp_categories cat ON cat.id = coalesce(mc.category_id, omc.category_id)
LEFT JOIN calls c ON c.device_native_id = d.device_native_id AND c.agent_type = inv.agent_type AND c.name_lc = inv.name_lc
```
