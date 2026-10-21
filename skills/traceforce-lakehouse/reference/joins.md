# Join patterns that are not obvious from the schema

These are starting points, not templates. Take only the join or attribution rule you need. If
none matches the question's shape, write the query from the table files. Do not carry over a
filter, time window or extra column because an example has it.

## Event to person

Use when a result should be per person. Email on the event when the agent emitted one,
otherwise the MDM owner of the device. Some agents (e.g. GitHub Copilot) report no end-user email, so without this
fallback those events vanish from per-person answers.

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
source. Cursor rows carry no `tool_decision`, so join the finding's `tool_use_id` to its
`postToolUse` row instead. On rows that reached the findings table, `source = 'hook'` means the user's own
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
                        AND e.ts BETWEEN f.detected_at - interval '1' hour AND f.detected_at + interval '1' hour
```

## Installed MCP servers to their actual use

Use when comparing inventory with usage. Inventory is per (device, agent); usage in the logs
is per (device serial, agent type, server name), matched case-insensitively. The same server
name can have several live inventory rows per device (one per project path or location), so
aggregate the inventory side or the counts multiply. Count calls, not rows: a call is 1-3 rows
(decision, result, span) sharing a `tool_call_id`, and Claude Code's `mcp_server_connection`
rows name the server without being a call (`operation` IS NULL there). Cursor's MCP rows carry
no `tool_call_id`, so id-less rows count one each. `LEFT JOIN` so a NULL count means
installed and never called, except for a browser connector: it is listed by display name while
its calls may carry the connector's id, so a NULL there does not mean unused. A NULL means unused only if
that device has `execute_tool` rows with `mcp_server_name` for that `agent_type` in the window;
otherwise say there is no call data. The `calls` side is per serial: a Windows placeholder serial
shared by several devices repeats its count on each of them (see identity.md). Product name and category come through `mcp_server_type` against
both catalogs, never through `mcp_servers.mcp_catalog_id` for org-private servers.

```sql
WITH calls AS (
  SELECT device_native_id, agent_type, lower(mcp_server_name) AS name_lc,
         count(DISTINCT tool_call_id) + sum(CASE WHEN tool_call_id IS NULL THEN 1 ELSE 0 END) AS calls, max(ts) AS last_call
  FROM agent_events
  WHERE mcp_server_name IS NOT NULL AND operation = 'execute_tool' AND ts > current_timestamp - interval '30' day
  GROUP BY 1, 2, 3
),
inventory AS (
  SELECT i.device_id, i.agent_type, lower(i.mcp_native_id) AS name_lc, i.mcp_server_type, count(*) AS configs
  FROM mcp_server_instances i WHERE i.deleted_at IS NULL GROUP BY 1, 2, 3, 4
)
SELECT d.device_native_id, inv.name_lc AS server, coalesce(mc.mcp_server_name, omc.mcp_server_name) AS product,
       cat.name AS category, inv.configs, c.calls, c.last_call
FROM inventory inv
JOIN devices d ON d.id = inv.device_id
LEFT JOIN mcp_catalog mc ON mc.mcp_server_type = inv.mcp_server_type
LEFT JOIN org_mcp_catalog omc ON omc.mcp_server_type = inv.mcp_server_type
LEFT JOIN mcp_categories cat ON cat.id = coalesce(mc.category_id, omc.category_id)
LEFT JOIN calls c ON c.device_native_id = d.device_native_id AND c.agent_type = inv.agent_type AND c.name_lc = inv.name_lc
```

## Issue to its type, and a finding to its criticality and issue

An issue (`agent_issues`, `mcp_server_issues`) reaches its type in two steps:
`issue_type_control_id` → `issue_type_controls.id`, then `issue_type_controls.issue_type_id` →
`issue_types.id`, which holds the name, `trigger_score` and `criticality`. Open, as the console
counts it, is `issue_status = 'active'` on an issue type with `applicable_to = 'instance'`;
'global' types are acknowledgment-only baselines the console does not list.

Every findings table carries `issue_detail`. A finding's criticality is the `issue_types` row with
the same `issue_detail` and `applicable_to = 'instance'`: `issue_types` has one row per
(`issue_detail`, `applicable_to`), so without that filter the join can double. A NULL
`issue_detail` (unknown category) has no criticality. A finding's issue is an `agent_issues` row on
the same agent account (the finding's conversation's `agent_account_id`) whose type has that
`issue_detail`. An account has at most one issue row per issue type; the issue may be
resolved or dismissed, and a finding may match none.

```sql
SELECT f.id, f.issue_detail, it.criticality, count(ai.id) AS issue_rows,
       sum(CASE WHEN ai.issue_status = 'active' THEN 1 ELSE 0 END) AS open_issue_rows
FROM sensitive_data_findings f
JOIN agent_conversations c ON c.id = f.conversation_id
LEFT JOIN issue_types it ON it.issue_detail = f.issue_detail AND it.applicable_to = 'instance'
LEFT JOIN issue_type_controls itc ON itc.issue_type_id = it.id
LEFT JOIN agent_issues ai ON ai.issue_type_control_id = itc.id AND ai.agent_account_id = c.agent_account_id
GROUP BY f.id, f.issue_detail, it.criticality
```

## User group to its devices

Manual groups list devices in `user_group_devices`. Groups synced from an identity provider list
people in `user_group_members`, who reach devices through the device's MDM owner. As in the
console, only live groups and memberships and `active` members count.

```sql
SELECT g.id AS user_group_id, g.name, gd.device_id
FROM user_groups g JOIN user_group_devices gd ON gd.user_group_id = g.id
WHERE g.deleted_at IS NULL
UNION ALL
SELECT g.id, g.name, d.id
FROM user_groups g
JOIN user_group_members m ON m.user_group_id = g.id
JOIN device_owner_mappings dom ON lower(dom.owner_email) = m.member_email
JOIN devices d ON d.device_native_id = dom.device_native_id AND d.deleted_at IS NULL
WHERE g.deleted_at IS NULL AND m.deleted_at IS NULL AND m.state = 'active'
```
