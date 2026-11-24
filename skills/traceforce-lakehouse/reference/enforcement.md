# Enforcement outcomes

Was an action actually blocked (vs just warned)? The findings tables record only what was
*detected*, and denied attempts are not stored as findings. As of ENG-654 the outcome is
recorded directly — see the authoritative source below. Historically it had to be reconstructed
from the agent_events logs per agent using the literals further down; that path is now the
fallback, not the primary answer.

**Authoritative source (ENG-654): the `enforcement_events` table.** Scout's hook now records what
it enforced — block/warn × deny/ask/deny_once/allowed_after_warn, per control and surface — as a
structured, append-only ledger, mirrored to the lakehouse as `enforcement_events` (see
`tables/enforcement_events.md`). Prefer it for "what did TraceForce prevent". The Prevented view
excludes `action = 'allowed_after_warn'` (the user overrode the warning) AND any `deny_once` whose
`(org_id, correlation_id)` has a matching `allowed_after_warn` — the hook stamps the same
`correlation_id` on a warn and its later override, so an overridden warn's `deny_once` row must be
suppressed too, or prevention is overstated. An `ask` row is the agent's own approval dialog, not a
prevention on its own: resolve it from `agent_events` on the same `tool_call_id` — Claude-family on
the `tool_decision` (accept = overridden; a reject is prevented UNLESS `source = 'hook'` — a
user-installed hook denying what TraceForce only asked, see the ENG-1213 bullet below), Copilot on its `execute_tool` span (a
clean span = overridden; `error_type` `denied`/`cancelled` = prevented — its permission span has no
call id, so key on the `execute_tool` span). Unknown only until such a row joins. Scout mints a
fresh `record_id` per PROCESS, so a double-registered hook (an exec-form and a shell-form copy of
one `PreToolUse` for the same command) writes TWO `deny`/`ask` rows for ONE action; count prevention
by distinct `(org_id, conversation_external_id, tool_use_id, control, surface, action)` when
`tool_use_id` is present (the UI's `blockIdentity` dedup key), never by raw `record_id` row. It covers
the hook-enforced agents (Claude Code, ChatGPT Codex, GitHub Copilot CLI, Cursor). The per-agent
heuristics below remain the fallback for activity that predates the ledger (or a lakehouse where it
is not yet populated), and for surfaces the hook does not cover — notably the Cowork inline proxy.

**Telling TraceForce's enforcement apart from the user's own hooks and the agent's native prompts
(ENG-1213).** How a TraceForce *warning* surfaces depends on agent and surface: Claude Code and
GitHub Copilot CLI **tool-call** warns are delivered *as the agent's own permission prompt* (a native
`ask` / `user_*`). Codex and Cursor tool-call warns, and **prompt / @-file** warns on the agents that
hook the prompt (Claude Code, Codex, Cursor), are `deny_once` denials instead. **GitHub Copilot has NO
prompt-surface sensitive-data enforcement** — scout hooks Copilot only on tool calls / file reads
(there is no prompt-submission hook), so a credential in a Copilot prompt is never scanned, warned, or
recorded (0 ledger rows); Copilot coverage is **file_read / tool_call only**. Separately, a TraceForce *block* is a hard deny that on Claude looks
identical to a user-installed hook's `tool_decision` `reject` (`source = 'hook'`). So the per-agent
heuristics below **cannot** separate them on their own (a `source = 'hook'` reject may be TraceForce's
block OR the user's hook; a reject on a native `ask` / `user_*` may be a TraceForce tool-call warn OR
the agent's own prompt). The `enforcement_events` ledger is the only reliable discriminator, joined on
`tool_use_id` (but see the per-agent join caveat below):

- A `tool_decision` `reject` with `source = 'hook'`, or any `ask` / `user_*`, with **no**
  `enforcement_events` row on the same `tool_use_id`, is **unknown** — a missing row does NOT prove it
  wasn't TraceForce. Ledger rows go missing in normal operation: the hook POSTs the record best-effort
  with no retry (a collector restart drops it), the exporter skips a session with no device GUID or
  scan credentials, a lambda savepoint can roll the insert back, and the ledger mirrors to the
  lakehouse DAILY while `agent_events` loads hourly. So treat absence as unknown, never as "not
  TraceForce"; the hourly `traceforce.enforcement` rows below close part — not all — of that gap.
- A TraceForce `ask` row **plus** a `source = 'hook'` reject on the same `tool_use_id` means a
  **user hook** denied what TraceForce only asked about.
- The enforcement records also surface in `agent_events` as hourly `traceforce.enforcement` rows,
  carrying the call's `tool_call_id` for **all four agents**. The hook emits the id as raw
  `tool_use_id` (it skips the transform that maps native events onto `gen_ai.tool.call.id`), so
  `ingest_agent_events` now reads `tool_call_id` as `COALESCE(gen_ai.tool.call.id, tool_use_id)` —
  native rows already have `gen_ai.tool.call.id` (no-op for them), and Claude/Codex/Cursor/Copilot
  enforcement rows recover it from `tool_use_id`. (Only a prompt or @-file enforcement, which has no
  tool call, stays NULL.) So count a call as TraceForce's when either the ledger OR a
  `traceforce.enforcement` row has that `tool_call_id`. These rows also carry no `user_email` and (for
  Codex) the turn id as `prompt_id`, and nothing excludes `event_name = 'traceforce.enforcement'` from
  the usage counts yet, so they inflate activity/prompt counts and Unattributed — exclude them there
  (follow-up).

Caveats: older scout builds write **no** ledger rows (use the heuristics for them), and ledger rows
are **unauthenticated claims** — the loopback receiver accepts any local process's record, so use
them to show what TraceForce enforced, never to suppress a finding or incident.

> These are agent/collector *behavior* literals, not schema generated from the proto or
> Terraform, so they can drift when scout or the collector changes. They are verified against
> scout source; re-verify on a scout/collector upgrade. Scout and the binary-processor now DO
> write a structured enforcement outcome into Supabase (ENG-654: `enforcement_events`); prefer
> it, and use these heuristics only where it is absent (pre-ledger activity, uncovered surfaces).

`sd_enforcement` and `containment_enforcement` are the policy MODE that was configured
(warn or block), never the outcome. Whether something was actually blocked lives in the event:

- Claude Code, `event_name = 'tool_decision'`: `decision = 'reject'` with
  `json_extract_scalar(attrs_json, '$.source') = 'hook'` is TraceForce's hook denying in block
  mode. `source LIKE 'user_%'` is the person declining a dialog (in warn mode that dialog was
  TraceForce's ask; otherwise Claude's own permission prompt). `source = 'config'` is Claude's
  own permission rules, never TraceForce. Values are `accept` / `reject`. The source lives on
  the `tool_decision` row as `$.source`; a rejected call produces no `tool_result` row, and
  `tool_result` rows carry only `$.success` for outcome. Claude emits the same
  `tool_decision` rows, but TraceForce installs no hook there, so a `hook` source on its rows is
  the user's own; its enforcement is the proxy (see Cowork below).
- Cowork: scout's inline proxy blocks with an HTTP 403 whose body is
  `{"error":"access_denied","message":"...blocked because it contains sensitive data."}` — the
  phrase is in `message`, not `error`. That body is not itself a log event: scout emits no
  `api_error`; any `api_error` row is Cowork's own telemetry, and the collector sets only
  `error_type` (from `status_code`), nothing under `$.error`. So a naive
  `$.error LIKE '%blocked...%'` predicate does not hold. Treat a Cowork block as not reliably
  detectable from the lake until a live `api_error` capture confirms the attribute and value.
- Cursor, `event_name = 'postToolUseFailure' AND error_type = 'permission_denied'`: TraceForce
  denied it only when BOTH hold — `json_extract_scalar(attrs_json, '$["cursor.error.message"]')`
  contains `[Traceforce` AND the containment mode stamp is present (`containment_enforcement`
  IN ('warn','block')). The tag alone is not enough; a tagged denial with no stamp stays the
  user's own. Cursor rows have no `decision`.
- Copilot: TraceForce *does* enforce on Copilot (a fail-closed policy hook returning
  deny/ask/block, gated on a Copilot rule being enforced), but Copilot rides a trace-only
  pipeline and traces are never stamped — the exporter strips `traceforce.*` off spans and
  leaves outcomes `UNSPECIFIED`. So a Copilot denial cannot be attributed to TraceForce from
  the lake: `decision` (`approved` / `cancelled` / `denied-interactively-by-user`) sits on separate
  `span_name = 'permission'` spans that carry no `tool_call_id`, so it cannot be joined to the
  call, and `error_type` (`cancelled` / `denied`) on its `execute_tool` spans is agent-native;
  both are indistinguishable from the user's own dialog. Do not read them as proof TraceForce
  did or didn't act; a real block on Copilot is simply not observable here.
- Claude Code sensitive data (prompt blocks): a blocked prompt still emits `user_prompt`
  stamped `sd_enforcement = 'block'`, with matched values masked. Masking is length-preserving:
  each matched value is overwritten with one `*` per byte (newlines kept), so the `*` run is
  exactly as long as the value — there is no fixed-length marker. Detect the block heuristically
  with `event_name = 'user_prompt' AND sd_enforcement = 'block' AND content_input LIKE '%********%'`;
  the eight-`*` run is only a threshold to skip incidental short `*` runs, so it can miss a
  matched value shorter than eight bytes. Needs redaction on (the default); with redaction off,
  prompt blocks are not observable, and blocked prompts never produce a finding row.
- Cursor sensitive-data blocks are not observable in the lake (no stamp, no event).
- On the findings tables, `outcome` is execution status and `finding_status` is reviewer
  triage; denied attempts never reach `connector_containment_findings`.
