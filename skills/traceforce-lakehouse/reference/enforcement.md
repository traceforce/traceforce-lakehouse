# Enforcement outcomes

Was an action actually blocked (vs just warned)? Supabase carries no blocked/warned column —
the findings tables record what was *detected*, and denied attempts are not stored as findings.
So this outcome is derived from the agent_events logs, per agent, using the literals below.

> These are agent/collector *behavior* literals, not schema generated from the proto or
> Terraform, so they can drift when scout or the collector changes. They are verified against
> scout source; re-verify on a scout/collector upgrade. If scout and the binary processor ever
> write a structured enforcement outcome into Supabase, mirror that column and prefer it over
> these heuristics.

`sd_enforcement` and `containment_enforcement` are the policy MODE that was configured
(warn or block), never the outcome. Whether something was actually blocked lives in the event:

- Claude Code, `event_name = 'tool_decision'`: `decision = 'reject'` with
  `json_extract_scalar(attrs_json, '$.source') = 'hook'` is TraceForce's hook denying in block
  mode. `source LIKE 'user_%'` is the person declining a dialog (in warn mode that dialog was
  TraceForce's ask; otherwise Claude's own permission prompt). `source = 'config'` is Claude's
  own permission rules, never TraceForce. Values are `accept` / `reject`. The source lives on
  the `tool_decision` row as `$.source`; a rejected call produces no `tool_result` row, and
  `tool_result` rows carry only `$.success` for outcome.
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
  the lake: `decision` (`approved` / `denied-interactively-by-user`) and `error_type = 'denied'`
  on its spans are agent-native and indistinguishable from the user's own dialog. Do not read
  them as proof TraceForce did or didn't act; a real block on Copilot is simply not observable here.
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
