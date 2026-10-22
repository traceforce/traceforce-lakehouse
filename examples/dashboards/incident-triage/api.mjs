// Endpoints for the incident triage dashboard; served by ../serve.mjs at /incident-triage/api/<name>.
export const title = "Incident triage";
export const description = "Sensitive data, risky actions and prompt injections, grouped into incidents per session and ranked by severity.";
export const order = 2;

// What the page may send. An empty person is unknown (NULL).
const TS = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\.\d{1,9})?$/;
export const params = {
  session_id: { pattern: /^[A-Za-z0-9._:-]{1,200}$/ },
  person: { pattern: /^[A-Za-z0-9._%+-]{1,128}@[A-Za-z0-9.-]{1,190}$/, emptyIsNull: true },
  since: { pattern: TS, timestamp: true },
  until: { pattern: TS, timestamp: true },
};

// With several lakes each query returns every lake's rows (see ../serve.mjs). Findings are snapshots of the
// same control plane, so a finding can be in more than one lake: keep the first lake's copy.
const latest = (rows, k) => rows.map(r => r[k]).filter(Boolean).sort().pop() ?? null;
const firstPer = (rows, key) => [...new Map(rows.map(r => [key(r), r]).reverse()).values()].reverse();

export const routes = {
  // Every finding and block of the last 90 days; the page groups and filters them.
  async overview(_, { runAll }) {
    const r = await runAll({ findings: ["findings"], blocks: ["blocks"], freshness: ["freshness"] });
    const findings = firstPer(r.findings, f => `${f.kind}|${f.id}`).sort((a, b) => (a.at > b.at) - (a.at < b.at));
    return { findings, blocks: r.blocks, findings_through: latest(r.freshness, "findings_through"),
      events_through: latest(r.freshness, "events_through"), generated_at: new Date().toISOString().slice(0, 16).replace("T", " ") + " UTC" };
  },
  // What happened in one session around its findings.
  async timeline(q, { run, arg }) {
    const events = await run("timeline", Object.fromEntries(["session_id", "person", "since", "until"].map(k => [k, arg(q, k)])));
    return { events: events.sort((a, b) => (a.ts > b.ts) - (a.ts < b.ts)) };
  },
};
