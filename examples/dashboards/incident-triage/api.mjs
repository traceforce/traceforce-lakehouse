// Endpoints for the incident triage dashboard; served by ../serve.mjs at /incident-triage/api/<name>.
export const title = "Incident triage";
export const description = "Sensitive data, risky actions and prompt injections, grouped into incidents per session and ranked by severity.";

// What the page may send. An empty person is unknown (NULL).
const TS = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\.\d{1,9})?$/;
export const params = {
  session_id: { pattern: /^[A-Za-z0-9._:-]{1,200}$/ },
  person: { pattern: /^[A-Za-z0-9._%+-]{1,128}@[A-Za-z0-9.-]{1,190}$/, emptyIsNull: true },
  since: { pattern: TS, timestamp: true },
  until: { pattern: TS, timestamp: true },
};

export const routes = {
  // Every finding and block of the last 90 days; the page groups and filters them.
  async overview(_, { runAll }) {
    const r = await runAll({ findings: ["findings"], blocks: ["blocks"], freshness: ["freshness"] });
    const [fresh] = r.freshness;
    return { findings: r.findings, blocks: r.blocks, findings_through: fresh.findings_through,
      events_through: fresh.events_through, generated_at: new Date().toISOString().slice(0, 16).replace("T", " ") + " UTC" };
  },
  // What happened in one session around its findings.
  async timeline(q, { run, arg }) {
    return { events: await run("timeline", Object.fromEntries(["session_id", "person", "since", "until"].map(k => [k, arg(q, k)]))) };
  },
};
