# Incident triage dashboard

Which sessions leaked sensitive data, ran risky actions or met a prompt injection, ranked by severity,
with what happened around each finding. Built from the three findings tables, `issue_types`,
`agent_conversations`, `agent_accounts` and `devices`, plus `agent_events` for blocks and each incident's
activity.

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
  awaiting or under review, or *Resolved*, any other status), finding type and user.
- **Totals**: critical incidents (other severities beneath), users affected and blocks.
- **Incidents**: one row per session with findings, most severe first, then most recent. Each shows
  the user, agent, device and what was found.
- **An incident**: click one to see its findings inside the session's activity. Each risky action is
  attached to the exact tool call (by `tool_call_id`) with its command and how it was approved
  (permission rules, the user, a hook). Sensitive-data and prompt-injection findings are attached to
  their message where the ids match, or placed at their time. The prompt that led to each finding,
  and two events either side, are shown; the rest collapse to a count (*Show every event* expands
  them). Commands are cut at 2,000 characters.
- **Findings per day** by kind, **top finding types**, **users** (click to filter), and
  **blocked by TraceForce**: denied attempts, which never become findings.

## Severity

A finding's severity is the criticality TraceForce gives the issue type it maps to
(`issue_types.criticality` on the finding's `issue_detail`, in the same bands as the console's risk
badge); a finding with no issue type ranks low. An incident takes its most severe finding.

## Caveats

- **Needs lakehouse module 1.4.0 or later** for `issue_types` and the findings' `issue_detail`. On an
  older module the page can't load from the lake until you re-apply Terraform.
- **The matched sensitive value is never in the lake.** Open the finding in the TraceForce console for
  its evidence.
- **Agent:** on lakehouses whose `agent_accounts.agent_type` is empty (older deployments), the agent
  comes from the session's events. Sessions with no events (for example a chat whose activity is not
  logged, or findings older than the event logs) show *Unknown agent*, and their incident shows findings only.
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
