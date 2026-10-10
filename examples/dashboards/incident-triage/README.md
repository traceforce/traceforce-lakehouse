# Incident triage dashboard

Which sessions leaked sensitive data, ran risky actions or met a prompt injection, ranked by severity,
with what happened around each finding. Built from the three findings tables, `agent_conversations`,
`agent_accounts` and `devices`, plus `agent_events` for blocks and each incident's activity.

## Run it

Start the dashboards server (see [`../README.md`](../README.md)) and open
http://localhost:8765/incident-triage/. Opened as a file (`open index.html`), the page shows generated
sample data and labels it as such.

| when | endpoint | queries |
|---|---|---|
| the page loads | `api/overview` | `findings`, `blocks`, `freshness`, in parallel |
| you open an incident | `api/timeline` | `timeline` for that session, 30 minutes either side of its findings |

## What it shows

- **Filters** for the last 7, 30 or 90 days (UTC, ending today), review status (*Open*, meaning
  awaiting or under review, or *All*), finding kind and person.
- **Totals**: incidents by severity, people affected, credentials exposed, destructive actions that
  ran, prompt injections, and blocks.
- **Incidents**: one row per session with findings, most severe first, then most recent. Each shows
  the person, agent, device and what was found.
- **An incident**: click one to see its findings inside the session's activity. Each risky action is
  attached to the exact tool call (by `tool_call_id`) with its command and how it was approved
  (permission rules, the user, a hook). Sensitive-data and prompt-injection findings are attached to
  their message where the ids match, or placed at their time. The prompt that led to each finding,
  and two events either side, are shown; the rest collapse to a count (*Show every event* expands
  them). Commands are cut at 2,000 characters.
- **Findings per day** by kind, **top finding types**, **people** (click to filter), and
  **blocked by TraceForce**: denied attempts, which never become findings.

## Severity

From the finding; an incident takes its most severe finding. The rubric is `severity()` in
`index.html` (and the page's footer); change both together.

| severity | findings |
|---|---|
| Critical | credentials (API keys, passwords, private keys, connection strings); identity or financial data (SSN, card numbers); destroying company data or infrastructure, or disabling device defenses, when it ran |
| High | prompt injections; changes to company systems (cloud resources, shared repos, databases, connector records) that ran |
| Medium | changes to the device or dev environment that ran |
| Low | contact details such as email addresses and phone numbers; anything unclassified |

A risky action that failed drops one step.

## Caveats

- **The matched sensitive value is never in the lake.** Open the finding in the TraceForce console for
  its evidence.
- **Agent:** on lakehouses whose `agent_accounts.agent_type` is empty (older deployments), the agent
  comes from the session's events. Sessions with no events (for example Claude web chats, or findings
  older than the event logs) show *Unknown agent*, and their incident shows findings only.
- **Blocks** are inferred from agent behavior, per the skill's `reference/enforcement.md`: Claude Code
  hook denials, tagged Cursor permission denials, and Claude Code prompts blocked for sensitive data.
  Copilot and Cowork blocks, and Cursor prompt blocks, leave no event.
- **Findings** come from daily snapshots of TraceForce's control plane, so a finding, or a status
  change made in the console, can take up to a day to appear. The header shows how current each
  source is.

## Queries

| file | grain | feeds |
|---|---|---|
| `findings.sql` | one row per finding (all three kinds), last 90 days | totals, incidents, charts |
| `blocks.sql` | one row per blocked action, last 90 days | blocks |
| `timeline.sql` | prompts, tool calls and flagged replies in one session and time window | an incident |
| `freshness.sql` | one row | the header |

`timeline.sql` has `{{session_id}}`, `{{person}}`, `{{since}}` and `{{until}}` placeholders that
`../serve.mjs` fills in. To run it by hand, replace them with literals.
