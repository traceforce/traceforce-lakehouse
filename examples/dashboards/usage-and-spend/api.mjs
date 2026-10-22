// Endpoints for the AI agent usage & spend dashboard; served by ../serve.mjs at /usage-and-spend/api/<name>.
export const title = "AI agent usage & spend";
export const description = "Who uses which AI agents, how much, and what it costs, down to each session's prompts.";
export const order = 1;

// What the page may send. An empty person is the unattributed bucket (NULL); an empty agent is every agent.
export const params = {
  person: { pattern: /^[A-Za-z0-9._%+-]{1,128}@[A-Za-z0-9.-]{1,190}$/, emptyIsNull: true },
  agent: { pattern: /^[a-z0-9_]{1,64}$/, emptyIsNull: true },
  session_id: { pattern: /^[A-Za-z0-9._:-]{1,200}$/ },
  since: { pattern: /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\.\d{1,9})?$/, timestamp: true },
};

// With several lakes each query returns every lake's rows (see ../serve.mjs): the latest value of a column,
// and one row per key keeping the one where the column is latest.
const latest = (rows, k) => rows.map(r => r[k]).filter(Boolean).sort().pop() ?? null;
const newestPer = (rows, key, k) => [...rows.reduce((m, r) => {
  const o = m.get(r[key]);
  if (!o || (r[k] || "") > (o[k] || "")) m.set(r[key], r);
  return m;
}, new Map()).values()];
// A session continued from one lake into the next comes back once per lake: add its parts together.
function mergeSessions(rows) {
  const m = new Map();
  for (const r of rows) {
    const k = `${r.agent}|${r.person}|${r.session_id}`, o = m.get(k);
    if (!o) { m.set(k, { ...r }); continue; }
    if (r.started_at < o.started_at) Object.assign(o, { started_at: r.started_at, device_native_id: r.device_native_id });
    if (r.ended_at > o.ended_at) o.ended_at = r.ended_at;
    o.models = [...new Set([o.models, r.models].filter(Boolean).flatMap(x => x.split(", ")))].sort().join(", ") || null;
    for (const c of ["prompts", "tool_calls", "input_tokens", "output_tokens", "cost_usd"]) if (r[c] != null) o[c] = (o[c] ?? 0) + r[c];
  }
  return [...m.values()];
}
const byTs = k => (a, b) => (a[k] > b[k]) - (a[k] < b[k]);

export const routes = {
  // Totals, charts and unattributed devices for the last 90 days.
  async overview(_, { runAll }) {
    const r = await runAll(Object.fromEntries(
      ["activity", "models", "unattributed", "unattributed_devices", "freshness"].map(k => [k, [k]])));
    const fresh = r.freshness;
    delete r.freshness;
    r.unattributed_devices = newestPer(r.unattributed_devices, "device_native_id", "last_seen_at");
    return { ...r, generated_at: new Date().toISOString().slice(0, 16).replace("T", " ") + " UTC",
      ingested_through: latest(fresh, "ingested_through"), events_through: latest(fresh, "events_through") };
  },
  // The latest sessions across everyone, for one agent or all, before a user is picked.
  async recent(q, { run, arg }) {
    const sessions = mergeSessions(await run("recent_sessions", { agent: arg(q, "agent"), since: arg(q, "since") }));
    // Each lake sends its latest 30; keep the latest 30 of all.
    sessions.sort(byTs("started_at")).reverse();
    return { sessions: sessions.slice(0, 30) };
  },
  // One person's sessions and tools.
  async person(q, { runAll, arg }) {
    const p = { person: arg(q, "person") };
    const r = await runAll({ sessions: ["sessions", p], tools: ["tools", p] });
    return { ...r, sessions: mergeSessions(r.sessions) };
  },
  // One session's prompts.
  async prompts(q, { run, arg }) {
    const prompts = await run("prompts", Object.fromEntries(["agent", "person", "session_id", "since"].map(k => [k, arg(q, k)])));
    return { prompts: prompts.sort(byTs("ts")) };
  },
};
