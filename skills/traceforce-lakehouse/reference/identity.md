# Identity: person, device, account

How to attribute an event or finding to a person, a device, and a corporate account.

- **Person** = `user_email` on the event, else the device's MDM owner
  (`device_owner_mappings` by `device_native_id`). Only if the device has no MDM owner, fall back
  to the single corporate account on that device in `agent_accounts` and label it a heuristic;
  more than one such account means unattributed.
- **Device**: join `devices` on `device_uuid` when the event has one, else on
  `device_native_id`. Windows serials can be placeholders shared by several machines: if a
  serial matches more than one live device, aggregate at the serial grain and report the
  device count behind it; do not attribute those events, or an MDM owner, to one machine.
- **Corporate account** = an `agent_email` whose domain is the customer's own email domain.
  Ask for the domain if you do not know it; list the distinct domains seen if in doubt.
- **Agent, as the console counts it** = an install's (`agent_type`, `coalesce(plan, 'unknown')`): start
  from `agent_instances` (`WHERE deleted_at IS NULL`), `LEFT JOIN agent_instances_accounts` (it
  has no `deleted_at`), `LEFT JOIN agent_accounts a ON a.id = ia.agent_account_id AND
  a.deleted_at IS NULL` (that filter must be in the ON clause, or account-less installs vanish).
  No signed-in account
  = plan 'unknown'; that is how Copilot appears. Never count agents from `agent_accounts` alone. A
  device's MCP count in the console is `COUNT(DISTINCT mcp_server_type)` over its live
  `mcp_server_instances`; the console hides `mcp_servers` rollups with `active_users = 0`.
- **Live inventory** = `deleted_at IS NULL` on devices, accounts, installs and MCP instances;
  a junction row is live only when both parents are. Do not filter `deleted_at` when walking
  from a finding to its account: signed-out accounts still own their past findings.
- Emails are stored byte-exact; `lower()` is a tolerance. If a lowercased join returns more
  than one account for an event, report the ambiguity instead of picking one.
