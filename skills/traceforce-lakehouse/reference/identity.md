# Identity: person, device, account, OS user

How to attribute an event or finding to a person, a device, a corporate account and an OS user.

- **Person** = `user_email` on the event, else the device's MDM owner
  (`device_owner_mappings` by `device_native_id`). Only if the device has no MDM owner, fall back
  to the single corporate account on that device in `agent_accounts` and label it a heuristic;
  more than one such account means unattributed.
- **Device**: join `devices` on `device_uuid` when the event has one, else on
  `device_native_id`. Windows serials can be placeholders shared by several machines: if a
  serial matches more than one live device, aggregate at the serial grain and report the
  device count behind it; do not attribute those events, or an MDM owner, to one machine.
- **Has used AI** = `agent_events` activity in the window, or a `last_active_at` in the window on an
  `agent_instances` row of a device the person owns (MDM owner) or on an `agent_accounts` row with
  their `agent_email`. `agent_events` alone misses agents whose activity is not logged.
- **Corporate account** = an `agent_email` whose domain is the customer's own email domain.
  Ask for the domain if you do not know it; list the distinct domains seen if in doubt.
- **Agent, as the console counts it** = an install's (`agent_type`, `coalesce(plan, 'unknown')`): start
  from `agent_instances i` (`WHERE i.deleted_at IS NULL`) and LEFT JOIN its live links and their
  live accounts as one unit: `LEFT JOIN (SELECT ia.agent_instance_id, a.plan FROM
  agent_instances_accounts ia JOIN agent_accounts a ON a.id = ia.agent_account_id AND
  a.deleted_at IS NULL WHERE ia.deleted_at IS NULL) l ON l.agent_instance_id = i.id`. No signed-in account
  = plan 'unknown'; that is how Copilot appears. Never count agents from `agent_accounts` alone. A
  device's MCP count in the console is `COUNT(DISTINCT mcp_server_type)` over its live
  `mcp_server_instances`.
- **Why a plan is unknown** (the console's "Unspecified"): `agent_instances.unknown_plan_reason`,
  meaningful only on installs whose unit row above has plan 'unknown'; 'cloud' pairs with
  `model_host`, and 'unknown' = no reason recorded. The console shows one reason per device per
  agent, the first of: cloud (aws_bedrock, then gcp_vertex, then unknown host) > api_key >
  usage_billed > plan_not_shared > no_account_found > no_sign_in > org_not_found >
  account_unreadable > not_supported > gateway. Skip 'unknown': a device with no other reason
  gets none.
- **OS user of an install** = the `username` under the install's OS uid/SID in `account_metadata`
  (`sandboxes.account_metadata` when `sandbox_id` is set, else `devices.account_metadata`):
  `json_extract_scalar(<map>, '$["' || <key> || '"].username')`. The key is `tenant`, except for
  `agent_deployment = 'browser'`, whose `tenant` is a web domain: there it is
  `json_extract_scalar(i.metadata, '$.uid')` (the latest OS user seen), and when that is absent the
  OS user is unknown (never use `tenant`). Show the username, never the raw uid/SID.
- **OS user of an MCP server instance** = its `metadata.uid`, resolved like an install's; a shared
  config lists only the first OS user. Browser and remote connectors have no uid: take
  `agent_account_id` -> its live `agent_instances_accounts` links -> each linked install's OS user
  (list them all).
- **Live inventory** = `deleted_at IS NULL` on devices, accounts, installs, MCP instances and the
  links between them (`agent_instances_accounts`, `mcp_server_agent_instances`); a link also
  needs both parents live.
  Do not filter `deleted_at` when walking from a finding to its account: signed-out accounts
  still own their past findings.
- Emails are stored byte-exact; `lower()` is a tolerance. If a lowercased join returns more
  than one account for an event, report the ambiguity instead of picking one.
