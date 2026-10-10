// Endpoints for the AI agent usage & spend dashboard; served by ../serve.mjs at /usage-and-spend/api/<name>.
export const title = "AI agent usage & spend";
export const description = "Who uses which AI agents, how much, and what it costs, down to each session's prompts.";

// What the page may send. An empty person is the unattributed bucket (NULL).
export const params = {
  person: { pattern: /^[A-Za-z0-9._%+-]{1,128}@[A-Za-z0-9.-]{1,190}$/, emptyIsNull: true },
  agent: { pattern: /^[a-z0-9_]{1,64}$/ },
  session_id: { pattern: /^[A-Za-z0-9._:-]{1,200}$/ },
  since: { pattern: /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\.\d{1,9})?$/, timestamp: true },
};

export const routes = {
  // Totals, charts and unattributed devices for the last 90 days.
  async overview(_, { runAll }) {
    const r = await runAll(Object.fromEntries(
      ["activity", "models", "unattributed", "unattributed_devices", "freshness"].map(k => [k, [k]])));
    const [fresh] = r.freshness;
    delete r.freshness;
    return { ...r, generated_at: new Date().toISOString().slice(0, 16).replace("T", " ") + " UTC",
      ingested_through: fresh.ingested_through, events_through: fresh.events_through };
  },
  // One person's sessions and tools.
  async person(q, { runAll, arg }) {
    const p = { person: arg(q, "person") };
    return runAll({ sessions: ["sessions", p], tools: ["tools", p] });
  },
  // One session's prompts.
  async prompts(q, { run, arg }) {
    return { prompts: await run("prompts", Object.fromEntries(["agent", "person", "session_id", "since"].map(k => [k, arg(q, k)]))) };
  },
};
