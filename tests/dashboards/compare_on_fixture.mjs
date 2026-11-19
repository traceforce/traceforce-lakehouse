#!/usr/bin/env node
// Live: the dashboards' Snowflake queries return the same rows as the Athena originals on a small fixture
// holding the cases a test lake rarely has (it may have no findings or blocks at all). Each query runs on both
// engines with the fixture as CTEs that shadow the real tables. Timestamps are offsets from the current date,
// to the millisecond, so the 90- and 91-day windows fall the same way on both. Timestamp strings must match
// exactly, because api.mjs sorts some of them as strings. Athena is the reference, with arbitrary() replaced by
// min() as the Snowflake versions use. Nothing is written to either lake.
//
//   node tests/dashboards/compare_on_fixture.mjs [prefix]   # e.g. incident-triage, or usage-and-spend/sessions
//
// Needs Node 18 or later, snowflake_query.sh's credentials for a user holding the reader role, and
// athena_query.sh's AWS credentials and region (any Athena lakehouse: only its workgroup is used).
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const DASH = join(ROOT, "examples", "dashboards");
const SCRIPTS = join(ROOT, "skills", "traceforce-lakehouse", "scripts");
const { ENGINES, buildSql, parseCsv } = await import(join(DASH, "engines.mjs"));
const PARAMS = Object.fromEntries(await Promise.all(["usage-and-spend", "incident-triage"]
  .map(async d => [d, (await import(join(DASH, d, "api.mjs"))).params])));

const H = 3600, D = 86400;
// Message text (prompts.sql, timeline.sql). Each m1 case is one log turn: a prompt event and, for the first 12,
// a response event a second later, cycling through each agent's event names. Values are JSON text as the agents
// store it; some are broken on purpose, including raw control characters, which Trino rejects in a string and,
// apart from tab, line feed and carriage return, between tokens too.
const BS = "\\";
const part = c => ({ type: "text", content: c });
const userMsg = (...c) => JSON.stringify([{ role: "user", parts: c.map(part) }]);
const asstMsg = (...c) => JSON.stringify([{ role: "assistant", parts: c.map(part) }]);
// A 1.1 MB value, built in SQL: Athena takes at most 256 KB of query text, and its repeat() at most 10,000
// copies and 1,000,000 bytes, so it joins two 550 KB halves.
const half = "array_join(repeat(array_join(repeat('x', 1000), ''), 550), '')";
const big = wrap => ({ snowflake: `'${wrap[0]}' || REPEAT('x', 1100000) || '${wrap[1]}'`,
  aws: `'${wrap[0]}' || ${half} || ${half} || '${wrap[1]}'` });
const PROMPT_CASES = [
  userMsg("hello"),
  `[{"role":"user","parts":[{"content":"first"}]},{"role":"assistant","parts":[{"content":"x"}]},{"role":"user","parts":[{"content":"second"}]}]`,
  userMsg("a", "b", "c"),
  `[{"role":"user","parts":[{"content":{"k":1}},{"content":[1]},{"content":5},{"content":1.5},{"content":true},{"content":null},{"content":12345678901234567890}]}]`,
  `[{"role":"user"}]`, `[{"role":"user","parts":[]}]`, `[{"role":"user","parts":null}]`, `[{"role":"user","parts":"oops"}]`,
  `[{"role":"user","parts":{"content":"x"}}]`, `[{"role":"user","parts":["str",{"content":"ok"}]}]`,
  "not json", `{"role":"user"}`, "[]", `[{"role":1,"parts":[{"content":"x"}]},{"role":"user","parts":[{"content":"y"}]}]`,
  `["user",{"role":"user","parts":[{"content":"y"}]}]`,
  `[{"role":"user","parts":[{"content":"a${BS}ud83d b"}]}]`, `[{"role":"user","parts":[{"content":"a${BS}ude00 b"}]}]`,
  `[{"role":"user","parts":[{"content":"a${BS}ud83d${BS}ude00 b"}]}]`, `[{"role":"user","parts":[{"content":"a${BS}${BS}ud83d b"}]}]`,
  `[{"role":"user","parts":[{"content":"a${BS}ud83d${BS}ud83d${BS}ude00 b"}]}]`, `[{"role":"user","parts":[{"content":"${BS}ude00${BS}ud83d"}]}]`,
  `[{"role":"user","parts":[{"content":"x${BS}uD83D"}]}]`, `[{"role":"user","parts":[{"content":"a${BS}${BS}${BS}ud83d b"}]}]`,
  `[{"role":"user","parts":[{"content":"a${BS}${BS}${BS}${BS}ud83d b"}]}]`, `[{"role":"us${BS}ud83der","parts":[{"content":"x"}]}]`,
  `[{"role":"user","parts":[{"content":"first","content":"last"}]}]`, `[{"role":"assistant","role":"user","parts":[{"content":"x"}]}]`,
  userMsg('line1\nline2 "q" \\ 中文 עברית'), `[{"role":"user","parts":[{"content":"x"}]}] junk`,
  `[{"role":"user","parts":[{"content":"a\u0001b"}]}]`, `[{"role":"user","parts":[{"content":"a\u0004b"}]}]`,
  `[{"role":"user","parts":[{"content":"x"}]}\u000b]`,
  userMsg("p".repeat(3999) + "\u{1F600}" + "tail"),
  big(['[{"role":"user","parts":[{"content":"', '"}]}]']),
];
const RESPONSE_CASES = [
  `[{"role":"assistant","parts":[{"content":"a"},{"content":"b"}]},{"role":"user","parts":[{"content":"u"}]},{"role":"assistant","parts":[{"content":"c"}]}]`,
  `[{"role":"assistant"},{"role":"assistant","parts":[{"content":"c"}]}]`, `[{"role":"assistant","parts":null},{"role":"assistant","parts":[{"content":"c"}]}]`,
  `[{"role":"assistant","parts":"s"},{"role":"assistant","parts":[{"content":"c"}]}]`, `[{"role":"assistant","parts":[]},{"role":"assistant","parts":[{"content":"c"}]}]`,
  userMsg("no assistant"), "nope", `{"role":"assistant"}`, "[]", asstMsg("r".repeat(1999) + "\u{1F600}" + "tail"),
  `[{"role":"assistant","parts":[{"content":"a\u0004b"}]}]`,
  big(['[{"role":"assistant","parts":[{"content":"', '"}]}]']),
];
function messageEvents() {
  const out = [], CO = "AGENT_IDENTITY_GITHUB_COPILOT", al = "alice@example.com";
  const n = Math.max(PROMPT_CASES.length, RESPONSE_CASES.length);
  const PROMPT_EVENTS = ["user_prompt", "beforeSubmitPrompt"], RESPONSE_EVENTS = ["assistant_response", "afterAgentResponse", "agent_response"];
  for (let i = 0; i < n; i++) {
    if (i < PROMPT_CASES.length) out.push(ev(CC, al, "D1", "m1", -5 * D + i * 10, { event_name: PROMPT_EVENTS[i % 2], signal: "log", prompt_id: `mp${i}`, content_input: PROMPT_CASES[i] }));
    if (i < RESPONSE_CASES.length) out.push(ev(CC, al, "D1", "m1", -5 * D + i * 10 + 1, { event_name: RESPONSE_EVENTS[i % 3], signal: "log", content_output: RESPONSE_CASES[i], model: "opus", input_tokens: i, cost_usd: 0.5 }));
  }
  // Turn 0's totals: an invoke_agent row (its tokens and model aren't counted), a call made of two rows sharing
  // an id, another call, and an id-less span (3 calls). Turn 1's models: repeated, out of order, and one with no
  // tokens or cost (not listed): "alpha, zeta".
  const m1 = (t, o) => ev(CC, al, "D1", "m1", -5 * D + t, { signal: "log", ...o });
  out.push(m1(2, { operation: "invoke_agent", signal: "span", model: "agentmodel", input_tokens: 999, output_tokens: 999, cost_usd: 1 }),
    m1(3, { operation: "execute_tool", tool_call_id: "k1", tool_name: "read" }),
    m1(4, { operation: "execute_tool", signal: "span", tool_call_id: "k1", tool_name: "read" }),
    m1(5, { operation: "execute_tool", tool_call_id: "k2", tool_name: "edit" }),
    m1(6, { operation: "execute_tool", signal: "span", tool_name: "bash" }),
    m1(12, { operation: "chat", model: "zeta", input_tokens: 5 }), m1(13, { operation: "chat", model: "alpha", output_tokens: 2 }),
    m1(14, { operation: "chat", model: "zeta", cost_usd: 0.25 }), m1(15, { operation: "chat", model: "nocost" }));
  // m2: Copilot chat spans. The same user message on several spans is one turn; a span with no user message
  // continues it; a changed message starts a turn, and so does going back to an earlier one.
  const span = (t, o) => ev(CO, al, "D1", "m2", -4 * D + t, { signal: "span", operation: "chat", ...o });
  out.push(span(0, { content_input: userMsg("q1"), content_output: asstMsg("a1 partial"), model: "gpt", input_tokens: 10 }),
    span(1, { content_input: userMsg("q1"), content_output: asstMsg("a1 final"), model: "gpt", input_tokens: 20 }),
    ev(CO, al, "D1", "m2", -4 * D + 2, { signal: "span", operation: "execute_tool", tool_name: "edit" }),
    span(3, { content_input: `[{"role":"system","parts":[{"content":"sys"}]}]`, model: "gpt-mini", input_tokens: 1 }),
    span(4, { content_input: userMsg("q2"), content_output: asstMsg("a2") }),
    span(5, { content_input: userMsg("q1"), content_output: "not json" }));
  // m3: the same log prompt twice is two turns. m4: no person (an unmapped device).
  out.push(ev(CC, al, "D1", "m3", -3 * D, { event_name: "user_prompt", signal: "log", content_input: userMsg("same") }),
    ev(CC, al, "D1", "m3", -3 * D + 5, { event_name: "user_prompt", signal: "log", content_input: userMsg("same") }),
    ev(CC, null, "D9", "m4", -3 * D, { event_name: "beforeSubmitPrompt", content_input: userMsg("who") }));
  // t1: the incident timeline. A prompt stored twice, an unparseable one, one with a raw control character;
  // call c1 is three rows (decision, an MCP span named mcp_tool, a result naming the tool, with long arguments);
  // c2 a rejected Bash call; c3 only a result; c5 a failed call; c6 a Claude Code MCP call whose decision row holds
  // the placeholder, its span no arguments and its result the real ones (a dispatch with nested queryParams.q); a row with an id but no tool event (not a call); id-less tool spans with and without an MCP
  // server; replies with flags (two flags, ] inside quotes, never closed, a newline inside, stored twice).
  // Person filter: another person's row, rows without an email, an uppercase email; window: rows outside it.
  const t = (dt, email, o) => ev(CC, email, "D1", "t1", -2 * D + dt, o);
  const flag = (id, text) => ({ content_output: text, attrs_json: JSON.stringify({ "gen_ai.response.id": id }) });
  out.push(t(-1000, al, { event_name: "user_prompt", content_input: userMsg("too early") }),
    t(0, al, { event_name: "user_prompt", prompt_id: "tp1", content_input: userMsg("hi") }),
    t(0, al, { event_name: "user_prompt", prompt_id: "tp1", content_input: userMsg("hi") }),
    t(1, null, { event_name: "beforeSubmitPrompt", generation_id: "tg2", content_input: "raw prompt" }),
    t(2, al, { event_name: "tool_decision", tool_call_id: "c1", tool_name: "mcp_tool", mcp_server_name: "srv", decision: "accept", attrs_json: '{"source":"config"}' }),
    t(3, al, { operation: "execute_tool", signal: "span", tool_call_id: "c1", tool_name: "mcp_tool", mcp_server_name: "srv" }),
    t(4, al, { event_name: "postToolUse", tool_call_id: "c1", tool_name: "fetch", tool_args: "q".repeat(2100) }),
    t(5, "ALICE@example.com", { event_name: "preToolUse", tool_call_id: "c2", tool_name: "Bash", decision: "reject", error_type: "denied", attrs_json: '{"source":"hook"}', tool_args: "rm -rf x" }),
    t(6, al, { event_name: "tool_result", tool_call_id: "c3" }),
    t(6.5, al, { event_name: "postToolUseFailure", tool_call_id: "c5", tool_name: "edit", error_type: "permission_denied" }),
    t(6.6, al, { event_name: "tool_decision", tool_call_id: "c6", tool_name: "mcp_tool", mcp_server_name: "sf", decision: "accept", tool_args: '{"mcp_server_name":"sf","mcp_tool_name":"dispatch"}' }),
    t(6.7, al, { operation: "execute_tool", signal: "span", tool_call_id: "c6", tool_name: "dispatch", mcp_server_name: "sf" }),
    t(6.8, al, { event_name: "tool_result", tool_call_id: "c6", tool_name: "mcp_tool", mcp_server_name: "sf",
      tool_args: '{"method":"GET","url":"/services/data/v60.0/query","skillId":"soql","queryParams":{"q":"SELECT Id FROM Account"}}' }),
    t(7.5, al, { event_name: "user_prompt", content_input: `[{"role":"user","parts":[{"content":"a\u0004b"}]}]` }),
    t(7, al, { event_name: "user_prompt", tool_call_id: "c4", content_input: userMsg("has an id") }),
    t(8, al, { operation: "execute_tool", signal: "span", mcp_server_name: "srv2" }),
    t(9, al, { operation: "execute_tool", signal: "span", tool_name: "read", tool_args: "f.txt", decision: "allow", attrs_json: '{"source":{"nested":1}}' }),
    t(10, al, { event_name: "assistant_response", ...flag("r1", '[PI_DETECTED source="web" instruction="x"] then text') }),
    t(11, al, { event_name: "assistant_response", ...flag("r2", '[PI_DETECTED source="a"]\n[PI_DETECTED source="b"]') }),
    t(12, al, { event_name: "assistant_response", ...flag("r3", '[PI_DETECTED source="has ] inside"] rest') }),
    t(13, al, { event_name: "assistant_response", ...flag("r4", "[PI_DETECTED never closed") }),
    t(14, al, { event_name: "assistant_response", ...flag("r5", "[PI_DETECTED line one\nline two]") }),
    t(14, al, { event_name: "assistant_response", ...flag("r5", "[PI_DETECTED line one\nline two]") }),
    t(15, "bob@example.com", { event_name: "user_prompt", content_input: userMsg("bob's prompt") }),
    t(16, null, { operation: "execute_tool", signal: "span", tool_name: "anon" }),
    t(1000, al, { event_name: "user_prompt", content_input: userMsg("too late") }));
  return out;
}
// [column, type]: the agent_events columns the queries read.
const EV = [["agent", "s"], ["user_email", "s"], ["device_native_id", "s"], ["session_id", "s"], ["ts", "t"],
  ["model", "s"], ["prompt_id", "s"], ["generation_id", "s"], ["tool_call_id", "s"], ["signal", "s"], ["operation", "s"],
  ["input_tokens", "i"], ["output_tokens", "i"], ["cache_read_tokens", "i"], ["cost_usd", "f"], ["tool_name", "s"],
  ["mcp_server_name", "s"], ["ingested_at", "t"], ["event_name", "s"], ["decision", "s"], ["error_type", "s"],
  ["containment_enforcement", "s"], ["sd_enforcement", "s"], ["content_input", "s"], ["tool_args", "s"], ["attrs_json", "s"], ["content_output", "s"]];
const CC = "AGENT_IDENTITY_CLAUDE_CODE", CU = "AGENT_IDENTITY_CURSOR", CX = "AGENT_IDENTITY_CHATGPT_CODEX";
const ev = (agent, email, dev, sess, ts, o = {}) => ({ agent, user_email: email, device_native_id: dev, session_id: sess,
  ts, ingested_at: -60, ...o });
const EVENTS = [
  // s1: one person, two devices (one NULL), two models and a NULL one, an invoke_agent row with tokens,
  // a call made of a log row named mcp_tool and a span naming the MCP server and tool ("fetch" sorts before
  // "mcp_tool", so MAX alone would pick the wrong one), a span with no id.
  ev(CC, "Alice@Example.com", "D1", "s1", -2 * D, { model: "opus", prompt_id: "p1", operation: "chat", signal: "log", input_tokens: 100, output_tokens: 20, cache_read_tokens: 5, cost_usd: 0.25 }),
  ev(CC, "alice@example.com", null, "s1", -2 * D + 60, { model: "sonnet", generation_id: "g1", operation: "chat", signal: "span", input_tokens: 50, cost_usd: 0.125 }),
  ev(CC, "alice@example.com", "D2", "s1", -2 * D + 120, { model: null, prompt_id: "p1", operation: "chat", signal: "log", input_tokens: 7 }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 180, { model: "opus", operation: "invoke_agent", signal: "span", input_tokens: 999, output_tokens: 999, cost_usd: 1.0 }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 240, { operation: "execute_tool", tool_call_id: "t1", tool_name: "mcp_tool", signal: "log" }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 241, { operation: "execute_tool", tool_call_id: "t1", tool_name: "fetch", mcp_server_name: "srv", signal: "span" }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 300, { operation: "execute_tool", tool_name: "bash", signal: "span" }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 301, { operation: "execute_tool", tool_name: "ignored", signal: "log" }),
  // The agent app's own calls, left out per call: a ccd_ call whose log row names no server, Claude Browser's
  // preview tool (its log row spells the server with a space), an id-less span on visualize, a server-less
  // ToolSearch, Codex's node-repl reset and an OpenAI tool on its connector hub, Cursor's app control. Counted:
  // a chat row sharing an app call's id, the same servers' other tools, and ToolSearch on a real server.
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 500, { operation: "execute_tool", tool_call_id: "a1", tool_name: "mcp_tool", signal: "log" }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 501, { operation: "execute_tool", tool_call_id: "a1", tool_name: "update_plan", mcp_server_name: "ccd_turn", signal: "span" }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 502, { operation: "chat", tool_call_id: "a1", input_tokens: 3, signal: "log" }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 503, { operation: "execute_tool", tool_call_id: "a2", tool_name: "mcp_tool", mcp_server_name: "Claude Browser", signal: "log" }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 504, { operation: "execute_tool", tool_call_id: "a2", tool_name: "preview_start", mcp_server_name: "Claude_Browser", signal: "span" }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 505, { operation: "execute_tool", tool_call_id: "a3", tool_name: "navigate", mcp_server_name: "Claude_Browser", signal: "span" }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 506, { operation: "execute_tool", tool_name: "show_widget", mcp_server_name: "visualize", signal: "span" }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 507, { operation: "execute_tool", tool_call_id: "a4", tool_name: "ToolSearch", signal: "span" }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 508, { operation: "execute_tool", tool_call_id: "a5", tool_name: "ToolSearch", mcp_server_name: "srv", signal: "span" }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 509, { operation: "execute_tool", tool_call_id: "a6", tool_name: "run_in_terminal", mcp_server_name: "terminal", signal: "span" }),
  ev(CX, "alice@example.com", "D1", "s8", -2 * D + 600, { prompt_id: "p9", operation: "chat", input_tokens: 1 }),
  ev(CX, "alice@example.com", "D1", "s8", -2 * D + 601, { operation: "execute_tool", tool_call_id: "a7", tool_name: "js_reset", mcp_server_name: "node-repl", signal: "log" }),
  ev(CX, "alice@example.com", "D1", "s8", -2 * D + 602, { operation: "execute_tool", tool_call_id: "a8", tool_name: "mcp__codex_apps__search_service__web_run", mcp_server_name: "codex_apps", signal: "log" }),
  ev(CX, "alice@example.com", "D1", "s8", -2 * D + 603, { operation: "execute_tool", tool_call_id: "a9", tool_name: "_fetch", mcp_server_name: "codex_apps", signal: "log" }),
  ev(CX, "alice@example.com", "D1", "s8", -2 * D + 604, { operation: "execute_tool", tool_call_id: "a10", tool_name: "js", mcp_server_name: "node_repl", signal: "log" }),
  ev(CU, null, "D4", "s3", -3 * D + 20, { operation: "execute_tool", tool_call_id: "a11", tool_name: "move_agent_to_root", signal: "log" }),
  ev(CU, null, "D4", "s3", -3 * D + 21, { operation: "execute_tool", tool_call_id: "a12", tool_name: "x", mcp_server_name: "cursor-app-control", signal: "log" }),
  // Codex prompts carry no id: counted by ts, so the one stored twice counts once (s8: 3 prompts).
  ev(CX, "alice@example.com", "D1", "s8", -2 * D + 590, { event_name: "user_prompt", signal: "log" }),
  ev(CX, "alice@example.com", "D1", "s8", -2 * D + 590, { event_name: "user_prompt", signal: "log" }),
  ev(CX, "alice@example.com", "D1", "s8", -2 * D + 595, { event_name: "user_prompt", signal: "log" }),
  // Noise sessions, hidden: startup and connection events, an app call, an invoke_agent span's tokens, a zero cost.
  // dan has nothing else (no activity row); D7 is an unattributed device with nothing else (no device row).
  ev(CC, "alice@example.com", "D1", "s12", -2 * D + 700, { event_name: "mcp_server_connection", signal: "log", cost_usd: 0 }),
  ev(CC, "alice@example.com", "D1", "s12", -2 * D + 701, { operation: "execute_tool", tool_call_id: "a13", tool_name: "update_plan", mcp_server_name: "ccd_turn", signal: "span" }),
  ev(CC, "alice@example.com", "D1", "s12", -2 * D + 702, { operation: "invoke_agent", signal: "span", input_tokens: 9, output_tokens: 9 }),
  ev(CC, "dan@example.com", "D1", "s13", -2 * D + 800, { event_name: "hook_registered", signal: "log" }),
  ev(CU, null, "D7", "s14", -2 * D + 900, { event_name: "sessionStart", signal: "log" }),
  // s2: no email; the person comes from the device's MDM owner (stored in upper case).
  ev(CC, null, "D3", "s2", -1 * D, { model: "opus", prompt_id: "p2", operation: "chat", input_tokens: 10, cost_usd: 0.5 }),
  // s3, s4: no person. D4 has two live device records, a deleted one and agent accounts; D5 has an MDM
  // record with no owner.
  ev(CU, null, "D4", "s3", -3 * D, { model: "auto", prompt_id: "p3", operation: "chat", input_tokens: 30, output_tokens: 3 }),
  ev(CU, null, "D4", "s3", -3 * D + 10, { operation: "execute_tool", tool_call_id: "t3", tool_name: "edit", signal: "log" }),
  ev(CU, null, "D5", "s4", -4 * D, { prompt_id: "p4", operation: "chat" }),
  // s5: starts just outside the 90-day window (inside the 91-day one) and continues inside it.
  ev(CC, "alice@example.com", "D1", "s5", -90 * D - H, { prompt_id: "p5", operation: "chat", input_tokens: 1 }),
  ev(CC, "alice@example.com", "D1", "s5", -89 * D, { prompt_id: "p6", operation: "chat", input_tokens: 2 }),
  // Outside every window.
  ev(CC, "alice@example.com", "D1", "s6", -200 * D, { prompt_id: "p7", operation: "chat", input_tokens: 4 }),
  // s7: recent, for since: starts exactly at the since boundary used below.
  ev(CU, "carol@example.com", "D6", "s7", -1 * H, { prompt_id: "p8", operation: "chat" }),
  // Blocks. Counted: a hook rejection (long tool_args, a fraction of a second in ts), a Cursor denial tagged
  // [Traceforce with an MCP server and no tool (person from the MDM owner), a masked prompt, a hook rejection with
  // no tool, a denied Read whose arguments are only on its span. Not counted: another source, an accept,
  // containment off, the message as an object or nested instead of a dotted key, attrs that aren't an object, an
  // unmasked prompt, and one outside the window.
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 400.123, { event_name: "tool_decision", decision: "reject", attrs_json: '{"source":"hook"}', tool_name: "Bash", tool_args: "a".repeat(598) + "\u{1F600}bc" }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 401, { event_name: "tool_decision", decision: "reject", attrs_json: '{"source":"config"}', tool_name: "Bash" }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 402, { event_name: "tool_decision", decision: "accept", attrs_json: '{"source":"hook"}', tool_name: "Bash" }),
  ev(CU, null, "D3", "s2", -1 * D + 10.5, { event_name: "postToolUseFailure", error_type: "permission_denied", containment_enforcement: "warn", mcp_server_name: "srv", attrs_json: '{"cursor.error.message":"Blocked by [Traceforce policy]"}' }),
  ev(CU, null, "D3", "s2", -1 * D + 11, { event_name: "postToolUseFailure", error_type: "permission_denied", containment_enforcement: "off", tool_name: "edit", attrs_json: '{"cursor.error.message":"[Traceforce"}' }),
  ev(CU, null, "D3", "s2", -1 * D + 12, { event_name: "postToolUseFailure", error_type: "permission_denied", containment_enforcement: "block", tool_name: "edit", attrs_json: '{"cursor.error.message":{"m":"[Traceforce"}}' }),
  ev(CU, null, "D3", "s2", -1 * D + 13, { event_name: "postToolUseFailure", error_type: "permission_denied", containment_enforcement: "block", tool_name: "edit", attrs_json: '{"cursor":{"error":{"message":"[Traceforce"}}}' }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 403, { event_name: "tool_decision", decision: "reject", attrs_json: "not json", tool_name: "Bash" }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 404, { event_name: "tool_decision", decision: "reject", attrs_json: '[{"source":"hook"}]', tool_name: "Bash" }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 405, { event_name: "user_prompt", sd_enforcement: "block", content_input: "my key is ********" }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 406, { event_name: "user_prompt", sd_enforcement: "block", content_input: "nothing masked" }),
  ev(CC, "alice@example.com", "D1", "s1", -3 * D, { event_name: "tool_decision", decision: "reject", attrs_json: '{"source":"hook"}' }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 410, { event_name: "tool_decision", tool_call_id: "b1", decision: "reject", attrs_json: '{"source":"hook"}', tool_name: "Read" }),
  ev(CC, "alice@example.com", "D1", "s1", -2 * D + 411, { operation: "execute_tool", signal: "span", tool_call_id: "b1", tool_name: "Read", tool_args: '{"file_path":"creds.txt"}' }),
  ev(CC, "alice@example.com", "D1", "s6", -95 * D, { event_name: "tool_decision", decision: "reject", attrs_json: '{"source":"hook"}', tool_name: "old" }),
  ...messageEvents(),
];
const MAPPINGS = [["D3", "BOB@EXAMPLE.COM"], ["D5", null], ["D6", "carol@example.com"]];
const DEVICES = [["1", "D4", "laptop-a", "macOS", -5 * H, null], ["2", "D4", "laptop-b", "Windows", -2 * H, null],
  ["3", "D4", "old", "Linux", -1 * H, -1 * D], ["4", "D5", null, null, -3 * H, null]];
// [id, device_id, agent_email, agent_type, deleted_at]. a1..a5 own the findings' conversations, with agent_type:
// uppercase; plain; a number (an agent newer than the exporter, named from the catalog); NULL (the agent comes
// from the session's events); empty (named from the catalog's '' row), on a signed-out account.
const ACCOUNTS = [["x1", "1", "Dave@Example.com", null, null], ["x2", "2", "dave@example.com", null, null], ["x3", "2", "", null, null],
  ["x4", "1", "gone@example.com", null, -1 * D], ["a1", null, "Alice@Example.com", "CLAUDE_CODE", null],
  ["a2", null, "bob@example.com", "cursor", null], ["a3", null, "carol@example.com", "17", null], ["a4", null, null, null, null],
  ["a5", null, "Erin@Example.com", "", -1 * D]];
const CATALOG = [["17", "New Agent (Beta)!"], ["", "Claude Code (Desktop)"], ["cursor", "Cursor"]];
// [id, agent_account_id, conversation_external_id, name]. c6's account doesn't exist, so its finding drops out.
// c7 has no agent_type and its session, s2, has two agents, so the agent is the session's MIN.
const CONVERSATIONS = [["c1", "a1", "s1", "Fix the bug"], ["c2", "a2", "s2", null], ["c3", "a3", "s9", "New agent"],
  ["c4", "a4", "s3", "No type"], ["c5", "a5", "s10", "Empty type"], ["c6", "a_missing", "s11", "Orphan"],
  ["c7", "a4", "s2", "Two agents"]];
// The instance row is the one that counts; sd_unknown has none, so its criticality is NULL.
const ISSUES = [["sd_email", "instance", "high"], ["sd_email", "global", "low"], ["sd_secret", "instance", "critical"],
  ["cc_exfil", "instance", "medium"], ["pi", "instance", "high"], ["pi", "global", "low"]];
// [id, conversation_id, device_id, message_timestamp, finding_status, category, type, file_id, encoding_type,
// message_external_id, issue_detail, created_at]: in a file and encoded, in a message, an unknown device and
// issue, one outside the window, one whose conversation doesn't exist, and two org custom types.
const SD = [["sd1", "c1", "1", -2 * D + 0.123, "open", "pii", "email", "f1", "base64", "m1", "sd_email", -1 * D],
  ["sd2", "c2", "4", -1 * D, "resolved", "secret", "aws_key", null, null, "m2", "sd_secret", -1 * D + 0.5],
  ["sd3", "c3", "99", -89 * D, "open", "pii", "phone", null, "hex", "m3", "sd_unknown", -2 * D],
  ["sd4", "c1", "1", -95 * D, "open", "pii", "email", null, null, "m4", "sd_email", -2 * D],
  ["sd5", "c_missing", "1", -1 * D, "open", "pii", "email", null, null, "m5", "sd_email", -2 * D],
  ["sd6", "c2", "4", -1 * D + 0.25, "open", "pii", "custom_100001", null, null, "m7", "sd_email", -1 * D],
  ["sd7", "c2", "4", -1 * D + 0.75, "open", "pii", "custom_100002", null, null, "m8", "sd_email", -1 * D]];
// [type, name]: an org custom type with a name (sd6) and one deleted since its finding (sd7, no row).
const CUSTOM_TYPES = [["custom_100001", "Project codename"], ["custom_100003", "Unused type"]];
// [id, conversation_id, device_id, detected_at, finding_status, risky_action_category, risky_action_subcategory,
// outcome, op, tool_name, operation, tool_use_id, issue_detail, created_at]: an empty operation, a set one, a
// NULL op (so a NULL detail), and a NULL operation on the same id as a sensitive-data finding (another kind).
const CC_ROWS = [["cc1", "c1", "2", -2 * D + 0.5, "open", "exfiltration", "upload", "blocked", "write", "gmail.send", "", "tu1", "cc_exfil", -1 * D],
  ["cc2", "c4", null, -3 * D, "open", "destructive", "delete", null, "delete", "drive", "files/abc", "tu2", "cc_exfil", -2 * D],
  ["cc3", "c5", "1", -1 * H, "open", "other", "other", "allowed", null, "x", "y", "tu3", null, -1 * H],
  ["sd1", "c1", "1", -1 * D, "open", "other", "other", null, "read", "x", null, "tu4", null, -1 * D]];
// [id, conversation_id, device_id, detected_at, finding_status, description, message_external_id, issue_detail,
// created_at]: a description longer than the 600-character cut, with an astral character at the cut.
const PI = [["pi1", "c1", "1", -2 * D + 0.999, "open", "d".repeat(599) + "\u{1F600}" + "tail", "m6", "pi", -1 * D],
  ["pi2", "c6", "1", -1 * D, "open", "orphan", "m7", "pi", -1 * D],
  ["pi3", "c7", null, -1 * D, "open", "two agents", "m8", "pi", -1 * D]];

// The fixture as CTEs in each dialect. Whole seconds and milliseconds are added separately: Athena's date_add
// takes a 32-bit amount, which 200 days in milliseconds overflows.
const ms = v => Math.round((v - Math.floor(v)) * 1000);
const DIALECT = {
  snowflake: {
    id: n => `"${n}"`,
    lit: (v, t) => v === null ? "NULL" : t === "t" ? `DATEADD('millisecond', ${ms(v)}, DATEADD('second', ${Math.floor(v)}, CURRENT_DATE()::TIMESTAMP_NTZ))` : t === "s" ? (typeof v === "object" ? v.snowflake : ENGINES.snowflake.quote(v)) : String(v),
    cast: { s: "VARCHAR", i: "BIGINT", f: "DOUBLE", t: "TIMESTAMP_NTZ(6)" },
  },
  aws: {
    id: n => n,
    lit: (v, t) => v === null ? "NULL" : t === "t" ? `date_add('millisecond', ${ms(v)}, date_add('second', ${Math.floor(v)}, CAST(current_date AS timestamp(6))))` : t === "s" ? (typeof v === "object" ? v.aws : ENGINES.aws.quote(v)) : String(v),
    cast: { s: "varchar", i: "bigint", f: "double", t: "timestamp(6)" },
  },
};
// The first row's casts set each column's name and type; later rows are bare values, which UNION ALL converts
// to those types. That keeps each query's SQL well under Linux's 128 KiB argument limit (see run).
function cte(d, name, cols, rows) {
  const body = rows.map((r, n) => `SELECT ${cols.map(([c, t], i) => n ? d.lit(r[i], t) : `CAST(${d.lit(r[i], t)} AS ${d.cast[t]}) AS ${d.id(c)}`).join(", ")}`).join(" UNION ALL ");
  return `${d.id(name)} AS (${body})`;
}
function fixture(cloud) {
  const d = DIALECT[cloud];
  return [
    cte(d, "agent_events", EV, EVENTS.map(e => EV.map(([c]) => e[c] ?? null))),
    cte(d, "device_owner_mappings", [["device_native_id", "s"], ["owner_email", "s"]], MAPPINGS),
    cte(d, "devices", [["id", "s"], ["device_native_id", "s"], ["friendly_name", "s"], ["platform", "s"], ["last_seen_at", "t"], ["deleted_at", "t"]], DEVICES),
    cte(d, "agent_accounts", [["id", "s"], ["device_id", "s"], ["agent_email", "s"], ["agent_type", "s"], ["deleted_at", "t"]], ACCOUNTS),
    cte(d, "agent_catalog", [["agent_type", "s"], ["agent_name", "s"]], CATALOG),
    cte(d, "agent_conversations", [["id", "s"], ["agent_account_id", "s"], ["conversation_external_id", "s"], ["name", "s"]], CONVERSATIONS),
    cte(d, "issue_types", [["issue_detail", "s"], ["applicable_to", "s"], ["criticality", "s"]], ISSUES),
    cte(d, "org_sensitive_data_custom_types", [["type", "s"], ["name", "s"]], CUSTOM_TYPES),
    cte(d, "sensitive_data_findings", [["id", "s"], ["conversation_id", "s"], ["device_id", "s"], ["message_timestamp", "t"], ["finding_status", "s"],
      ["category", "s"], ["type", "s"], ["file_id", "s"], ["encoding_type", "s"], ["message_external_id", "s"], ["issue_detail", "s"], ["created_at", "t"]], SD),
    cte(d, "connector_containment_findings", [["id", "s"], ["conversation_id", "s"], ["device_id", "s"], ["detected_at", "t"], ["finding_status", "s"],
      ["risky_action_category", "s"], ["risky_action_subcategory", "s"], ["outcome", "s"], ["op", "s"], ["tool_name", "s"], ["operation", "s"],
      ["tool_use_id", "s"], ["issue_detail", "s"], ["created_at", "t"]], CC_ROWS),
    cte(d, "prompt_injection_findings", [["id", "s"], ["conversation_id", "s"], ["device_id", "s"], ["detected_at", "t"], ["finding_status", "s"],
      ["description", "s"], ["message_external_id", "s"], ["issue_detail", "s"], ["created_at", "t"]], PI),
  ].join(",\n");
}
function withFixture(cloud, sql) {
  const body = sql.replace(/^(\s*--[^\n]*\n)*/, "");
  return /^\s*WITH\b/i.test(body) ? body.replace(/^\s*WITH\b/i, `WITH ${fixture(cloud)},`) : `WITH ${fixture(cloud)}\n${body}`;
}
function run(cloud, dash, name, values) {
  const e = ENGINES[cloud];
  let text = readFileSync(join(DASH, dash, e.queries, `${name}.sql`), "utf8");
  // Athena's arbitrary() returns any non-null value (a session on several devices: any of them), the Snowflake
  // versions MIN. With min() on both, a NULL or a different value still differs.
  if (cloud === "aws") text = text.replace(/\barbitrary\(/g, "min(");
  const sql = withFixture(cloud, buildSql(e, text, PARAMS[dash], values, [], name));
  // The SQL is one argument, and Linux allows 128 KiB per argument including its terminating NUL, so at most
  // 131,071 bytes of text (macOS has no per-argument limit).
  if (Buffer.byteLength(sql) >= 128 * 1024) throw new Error(`${cloud} ${name}: ${Buffer.byteLength(sql)} bytes of SQL, at or over Linux's 128 KiB argument limit; shrink the fixture`);
  const out = execFileSync(join(SCRIPTS, e.script), [sql],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, TRACEFORCE_LAKEHOUSE_MAX_ROWS: "0" },
      maxBuffer: 1 << 30 }); // every row, so past execFileSync's 1 MiB default
  return parseCsv(out, { lowerHeader: e.lowerHeader, warn: () => {} });
}

const norm = v => typeof v === "number" ? Math.round(v * 1e6) / 1e6 : v;
const canon = list => list.map(r => JSON.stringify(Object.keys(r).sort().map(k => [k, norm(r[k])]))).sort();

const U = "usage-and-spend", I = "incident-triage";
// The message cases. A later since for m1 and a narrow timeline window come from Athena's rows: the window runs
// from the stored-twice prompt to the anonymous span, so the rows 1000 s before and after drop out.
function messageCases() {
  if (![`${U}/prompts`, `${I}/timeline`].some(c => c.startsWith(process.argv[2] || ""))) return [];
  const all = { since: "2000-01-01 00:00:00", until: "2100-01-01 00:00:00" }, al = "alice@example.com";
  const m1 = run("aws", U, "prompts", { agent: "claude_code", person: al, session_id: "m1", since: all.since });
  const t1 = run("aws", I, "timeline", { session_id: "t1", person: "", ...all });
  const window = { since: t1.find(r => r.text === "hi")?.ts, until: t1.find(r => r.tool === "anon")?.ts };
  return [
    [U, "prompts", { agent: "claude_code", person: al, session_id: "m1", since: all.since }],
    [U, "prompts", { agent: "claude_code", person: al, session_id: "m1", since: m1[5]?.ts }],
    [U, "prompts", { agent: "github_copilot", person: al, session_id: "m2", since: all.since }],
    [U, "prompts", { agent: "claude_code", person: al, session_id: "m3", since: all.since }],
    [U, "prompts", { agent: "claude_code", person: "", session_id: "m4", since: all.since }],
    [I, "timeline", { session_id: "t1", person: al, ...all }],
    [I, "timeline", { session_id: "t1", person: "", ...all }],
    [I, "timeline", { session_id: "t1", person: "bob@example.com", ...all }],
    [I, "timeline", { session_id: "t1", person: al, ...window }],
  ];
}
const since = run("aws", U, "recent_sessions", { agent: "", since: "2000-01-01 00:00:00" })
  .find(r => r.session_id === "s7")?.started_at;
const cases = [[U, "freshness", {}], [U, "models", {}], [U, "activity", {}], [U, "unattributed", {}], [U, "unattributed_devices", {}],
  [U, "sessions", { person: "alice@example.com" }], [U, "sessions", { person: "bob@example.com" }], [U, "sessions", { person: "" }],
  [U, "sessions", { person: "dan@example.com" }],
  [U, "tools", { person: "alice@example.com" }], [U, "tools", { person: "" }],
  [U, "recent_sessions", { agent: "", since: "2000-01-01 00:00:00" }], [U, "recent_sessions", { agent: "cursor", since: "2000-01-01 00:00:00" }],
  [U, "recent_sessions", { agent: "", since }],
  [I, "freshness", {}], [I, "findings", {}], [I, "blocks", {}],
  ...messageCases()].filter(([d, n]) => `${d}/${n}`.startsWith(process.argv[2] || ""));
if (!cases.length) { console.error(`no case matches "${process.argv[2]}" (a prefix of <dashboard>/<query>)`); process.exit(2); }
// The fixture's timestamps and the queries' 90- and 91-day windows both come from each query's CURRENT_DATE,
// so a case's two queries must run on the same UTC day. If they may not have (within 2 minutes of midnight,
// for clock skew with the engines), wait until 2 minutes past midnight and run the case again.
const DAY = 86_400_000, SKEW = 120_000;
async function sameDay(f) {
  for (;;) {
    const start = Date.now(), r = f(), end = Date.now();
    const day = Math.floor((end + SKEW) / DAY);
    if (Math.floor((start - SKEW) / DAY) === day) return r;
    await new Promise(done => setTimeout(done, Math.max(0, day * DAY + SKEW - Date.now())));
  }
}

let fails = 0;
for (const [dash, name, values] of cases) {
  const [sf, at] = await sameDay(() => [run("snowflake", dash, name, values), run("aws", dash, name, values)]);
  const a = canon(sf), b = canon(at), same = JSON.stringify(a) === JSON.stringify(b);
  console.log(`${same ? "ok  " : "DIFF"} ${dash}/${name} ${JSON.stringify(values)}: ${sf.length} rows${same ? "" : ` (Athena ${at.length})`}`);
  if (!same) {
    fails++;
    for (const r of a.filter(x => !b.includes(x)).slice(0, 4)) console.log(`  only Snowflake: ${r}`);
    for (const r of b.filter(x => !a.includes(x)).slice(0, 4)) console.log(`  only Athena:    ${r}`);
  }
}
console.log(fails ? `${fails} differ` : `all ${cases.length} match`);
process.exit(fails ? 1 : 0);
