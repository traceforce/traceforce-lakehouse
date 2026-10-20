# AI agent usage & spend dashboard

A page showing who uses which AI agents, how much, and what it costs. Built from
`agent_events` (plus `device_owner_mappings` for attribution) in your TraceForce lakehouse.
Every panel is queried live from the lake. Nothing is cached on disk.

## Run it

Start the dashboards server (see [`../README.md`](../README.md)) and open
http://localhost:8765/usage-and-spend/. Opened as a file (`open index.html`), the page shows generated
sample data and labels it as such.

The page fetches each piece only when it needs it, through the endpoints in `api.mjs`:

| when | endpoint | queries |
|---|---|---|
| the page loads | `api/overview` | `activity`, `models`, `unattributed`, `unattributed_devices`, `freshness`, in parallel |
| you pick a user or device | `api/person` | `sessions`, `tools` for that user |
| you open a session | `api/prompts` | `prompts` for that session |

Each takes a few seconds. The date range and agent filters apply in the page, so they're instant.
Prompt text leaves the lake only for the session you open.

## What it shows

- **Filters** for the last 7, 30 or 90 days (UTC, ending today),
  agent and user. Every panel follows them.
- **Totals**: reported cost, active users, sessions, prompts, tool calls, tokens and cache share.
- **Daily cost by agent**, **daily sessions by agent**, **top users by cost**, **cost by model**,
  and a **per-agent table**. Each chart has a table view.
- **User drill-down**: click a user (bar or table row) or pick one in the filter to see their
  sessions (start time, agent, duration, models, prompts, tool calls, tokens and cost; sortable,
  newest first) and their top tools. MCP tools show as `server/tool`.
- **Prompts in a session**: click a session to expand its prompts. Each card shows the time, duration,
  model, tool calls, tokens and cost, then the prompt and the agent's final response. The text is
  as TraceForce stored it: values your redaction policy matched show as `****`. Prompts are cut at
  4,000 characters and responses at 2,000.
- **Unattributed activity by device**: each device serial behind the *Unattributed* bucket, with
  its name, MDM status and the agent accounts signed in on it. When there's exactly one account,
  it's flagged as the likely owner (a hint, not proof). Click a device for its sessions. The fix
  is to assign the device an owner in your MDM.

## How the numbers are counted

- **User** is the event's `user_email`, else the device's MDM owner. With neither, the row is
  *Unattributed*. GitHub Copilot never reports an email, so it relies on MDM.
- **Sessions** are distinct `session_id`s, counted once on the UTC day they started.
  **Prompts** are distinct `prompt_id` / `generation_id`. **Tool calls** are distinct
  `tool_call_id`s on `execute_tool` rows, plus Copilot's id-less tool spans.
- **Cost and tokens** are what the agent reports. Cursor reports neither. GitHub Copilot and
  ChatGPT Codex report tokens but no cost, so their spend is excluded from the totals, and the
  page says so. `invoke_agent` spans are skipped so tokens aren't counted twice.
- The agent comes from the `agent` column (`AGENT_IDENTITY_*`), so the queries work whether
  `agent_type` is stored as text or as the older integer code.

## Queries

| file | grain | feeds |
|---|---|---|
| `activity.sql` | day × agent × person | totals, daily charts, people, per-agent table |
| `models.sql` | day × agent × model | cost by model |
| `sessions.sql` | one row per session, for one person | person drill-down |
| `tools.sql` | day × agent × tool, for one person | top tools |
| `unattributed.sql` | day × agent × device serial, no person | unattributed by device |
| `unattributed_devices.sql` | device serial | device name, MDM status, signed-in accounts |
| `prompts.sql` | one row per prompt, for one session | prompts in a session |
| `freshness.sql` | one row | "Loaded through" in the header |

A prompt runs from one user prompt to the next in the same session, and the model calls, tool calls
and response in between are credited to it. This works for agents that emit no prompt id. Spend
logged before a session's first prompt isn't credited to any prompt. The prompts are what each agent
logs as one: Claude Code also logs its own task notifications as prompts, so they appear here too.

All read the last 90 days. `sessions.sql`, `tools.sql` and `prompts.sql` have `{{person}}`-style
placeholders that `../serve.mjs` fills in. To run one by hand, replace them with literals (`NULL` for the
unattributed person).

## Other clouds

The SQL in `queries/` is Athena (Trino). For BigQuery or Snowflake, translate it as described in
the skill's `SKILL.md` and point `QUERY` in `../serve.mjs` at `bq_query.sh` or `snowflake_query.sh`.
The page reads the same JSON either way.
