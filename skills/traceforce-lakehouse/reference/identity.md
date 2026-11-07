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
- **Why a plan is unknown** (the console calls plan unknown "Unspecified"): `agent_instances.unknown_plan_reason`.
  A mixed install counts under both its plan and plan unknown. To match the console, take one
  reason per device per `agent_type` from the live installs on live devices whose unit row above has
  plan unknown (no live account link, or a linked account with plan 'unknown'). Keep the unit's
  LEFT JOIN: cloud and api_key installs are unlinked from their account, and not_supported /
  no_account_found installs never had a link. Keep only the ten reasons ranked below: devices
  with only 'unknown' (or a newer value) get no reason, so the counts can sum to less than the
  `active_users` of the `agents` row with plan 'unknown'. Rank cloud > api_key > usage_billed >
  plan_not_shared > no_account_found > no_sign_in > org_not_found > account_unreadable >
  not_supported > gateway;
  among equal reasons prefer `model_host` 'aws_bedrock', then 'gcp_vertex', then 'unknown'. Label
  cloud by its `model_host`: cloud_aws_bedrock / cloud_gcp_vertex / cloud.

  ```sql
  SELECT agent_type, reason, count(*) AS devices FROM (
    SELECT i.agent_type, i.device_id,
           min_by(CASE WHEN i.unknown_plan_reason = 'cloud' AND i.model_host <> 'unknown'
                       THEN 'cloud_' || i.model_host ELSE i.unknown_plan_reason END,
                  CASE i.unknown_plan_reason WHEN 'cloud' THEN 1 WHEN 'api_key' THEN 2
                    WHEN 'usage_billed' THEN 3 WHEN 'plan_not_shared' THEN 4 WHEN 'no_account_found' THEN 5
                    WHEN 'no_sign_in' THEN 6 WHEN 'org_not_found' THEN 7 WHEN 'account_unreadable' THEN 8
                    WHEN 'not_supported' THEN 9 ELSE 10 END * 10
                  + CASE i.model_host WHEN 'aws_bedrock' THEN 1 WHEN 'gcp_vertex' THEN 2 ELSE 3 END) AS reason
    FROM agent_instances i
    JOIN devices d ON d.id = i.device_id AND d.deleted_at IS NULL
    LEFT JOIN (<the unit above>) l ON l.agent_instance_id = i.id
    WHERE i.deleted_at IS NULL AND coalesce(l.plan, 'unknown') = 'unknown'
      AND i.unknown_plan_reason IN ('cloud', 'api_key', 'usage_billed', 'plan_not_shared',
        'no_account_found', 'no_sign_in', 'org_not_found', 'account_unreadable', 'not_supported', 'gateway')
    GROUP BY 1, 2) t
  GROUP BY 1, 2
  ```
- **OS user of an install** = the `username` in `account_metadata` under the install's OS uid/SID.
  The key is `tenant`, except for `agent_deployment = 'browser'`, whose `tenant` is a web domain:
  there it is `json_extract_scalar(i.metadata, '$.uid')` (the latest OS user seen), and when that
  is absent the OS user is unknown; never resolve a browser row's `tenant`. The map is
  `sandboxes.account_metadata` when `sandbox_id` is set, else `devices.account_metadata`:
  `json_extract_scalar(CASE WHEN i.sandbox_id IS NOT NULL THEN s.account_metadata ELSE
  d.account_metadata END, '$["' || uid || '"].username')`, with `uid` the key above. Show the
  username, never the raw uid/SID.
- **OS user of an MCP server instance**: for a filesystem MCP, `json_extract_scalar(metadata,
  '$.uid')` resolved the same way (map chosen by the MCP row's own `sandbox_id`); it equals the
  `tenant` of its `mcp_server_agent_instances` install. A shared config lists only the first OS
  user, so other users of it are not counted. Browser connectors and remote-connector MCPs have
  no uid and no link: take `agent_account_id` → its live `agent_instances_accounts` links → each
  linked install, then the install rule above. An account linked to several installs gives one OS
  user per install: list them all. For current use, drop links not in their install's latest scan
  (`last_seen_at` rule under Live inventory).
- **Live inventory** = `deleted_at IS NULL` on devices, accounts, installs, MCP instances and the
  links between them (`agent_instances_accounts`, `mcp_server_agent_instances`); a link also
  needs both parents live. A live link with an older `last_seen_at` than its install was not in
  the install's latest scan (link tables: `last_seen_at`, `deleted_at`).
  Do not filter `deleted_at` when walking from a finding to its account: signed-out accounts
  still own their past findings.
- Emails are stored byte-exact; `lower()` is a tolerance. If a lowercased join returns more
  than one account for an event, report the ambiguity instead of picking one.
