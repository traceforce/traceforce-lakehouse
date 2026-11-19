#!/usr/bin/env node
// Live: the dashboards' Snowflake queries return the same rows as the Athena originals, for a Snowflake and
// an Athena lakehouse loaded from the same logs bucket. Each query is rendered by engines.mjs as serve.mjs
// renders it (except that Athena's arbitrary() becomes min(), see run) and run through the skill's scripts;
// timestamps are compared at 6 fraction digits. ingested_through (usage-and-spend) and events_through
// (incident-triage) are left out: they're when each engine loaded the rows.
//
//   node tests/dashboards/compare_snowflake_athena.mjs
//
// Needs Node 18 or later, snowflake_query.sh's credentials for a user holding the reader role, and
// athena_query.sh's AWS credentials and region. The sample people, agent and since come from the data.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const DASH = join(ROOT, "examples", "dashboards");
const SCRIPTS = join(ROOT, "skills", "traceforce-lakehouse", "scripts");
const { ENGINES, buildSql, parseCsv } = await import(join(DASH, "engines.mjs"));

function run(cloud, dash, name, values) {
  const engine = ENGINES[cloud];
  const { params } = PARAMS[dash];
  let text = readFileSync(join(DASH, dash, engine.queries, `${name}.sql`), "utf8");
  // Athena's arbitrary() returns any non-null value (a session on several devices: any of them), the Snowflake
  // versions MIN, so the reference uses min() here: both skip NULLs, and the rows compare exactly.
  if (cloud === "aws") text = text.replace(/\barbitrary\(/g, "min(");
  const out = execFileSync(join(SCRIPTS, engine.script), [buildSql(engine, text, params, values, [], name)],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, TRACEFORCE_LAKEHOUSE_MAX_ROWS: "0" },
      maxBuffer: 1 << 30 }); // every row, so past execFileSync's 1 MiB default
  return parseCsv(out, { lowerHeader: engine.lowerHeader, warn: () => {} });
}
const PARAMS = { "usage-and-spend": await import(join(DASH, "usage-and-spend", "api.mjs")),
  "incident-triage": await import(join(DASH, "incident-triage", "api.mjs")) };

const TS = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\.\d+)?$/;
const norm = v => v === null ? null : typeof v === "number" ? Math.round(v * 1e6) / 1e6
  : TS.test(v) ? v.replace(/(\.\d+)?$/, m => (m || ".").padEnd(7, "0").slice(0, 7)) : v;
const rows = (list, skip) => list.map(r => JSON.stringify(Object.keys(r).filter(k => !skip.includes(k)).sort()
  .map(k => [k, norm(r[k])]))).sort();

// Sample values from the data: up to three people, the unattributed bucket, the busiest agent, a since that
// splits the recent sessions, and the recent sessions themselves for the prompts and the incident timeline.
const U = "usage-and-spend", I = "incident-triage";
const activity = run("aws", U, "activity", {});
const people = [...new Set(activity.map(r => r.person).filter(Boolean))].slice(0, 3);
const agent = Object.entries(activity.reduce((m, r) => ({ ...m, [r.agent]: (m[r.agent] || 0) + r.sessions }), {}))
  .sort((a, b) => b[1] - a[1])[0]?.[0];
const recent = run("aws", U, "recent_sessions", { agent: "", since: "2000-01-01 00:00:00" });
const middle = recent[Math.floor(recent.length / 2)]?.started_at || "2000-01-01 00:00:00";
const cases = [
  ...["freshness", "models", "activity", "unattributed", "unattributed_devices"].map(q => [q, {}]),
  ...[...people, ""].flatMap(p => [["sessions", { person: p }], ["tools", { person: p }]]),
  ["recent_sessions", { agent: "", since: "2000-01-01 00:00:00" }],
  ["recent_sessions", { agent: "", since: middle }],
  ...(agent ? [["recent_sessions", { agent, since: "2000-01-01 00:00:00" }]] : []),
].map(c => [U, ...c]).concat(["freshness", "findings", "blocks"].map(q => [I, q, {}]),
  recent.flatMap(s => [[U, "prompts", { agent: s.agent, person: s.person || "", session_id: s.session_id, since: s.started_at }],
    [I, "timeline", { session_id: s.session_id, person: s.person || "", since: s.started_at, until: s.ended_at }]]));
const SKIP = { [`${U}/freshness`]: ["ingested_through"], [`${I}/freshness`]: ["events_through"] };

// The queries' 90- and 91-day windows come from each query's CURRENT_DATE, so a case's two queries must run on
// the same UTC day. If they may not have (within 2 minutes of midnight, for clock skew with the engines), wait
// until 2 minutes past midnight and run the case again.
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
  const skip = SKIP[`${dash}/${name}`] || [];
  const a = rows(sf, skip), b = rows(at, skip);
  const same = JSON.stringify(a) === JSON.stringify(b);
  console.log(`${same ? "ok  " : "DIFF"} ${dash}/${name} ${JSON.stringify(values)}: ${sf.length} rows${same ? "" : ` (Athena ${at.length})`}`);
  if (!same) {
    fails++;
    for (const r of a.filter(x => !b.includes(x)).slice(0, 3)) console.log(`  only Snowflake: ${r}`);
    for (const r of b.filter(x => !a.includes(x)).slice(0, 3)) console.log(`  only Athena:    ${r}`);
  }
}
console.log(fails ? `${fails} differ` : `all ${cases.length} match`);
process.exit(fails ? 1 : 0);
