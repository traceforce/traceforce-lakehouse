#!/usr/bin/env node
// Serve the TraceForce lakehouse dashboards, querying the lakehouse live: Athena on AWS, BigQuery on GCP.
//
//   node serve.mjs              # check AWS access, then serve http://localhost:8765
//   node serve.mjs --cloud gcp  # the same for a GCP (BigQuery) lakehouse (default: --cloud aws)
//   node serve.mjs --cloud gcp,aws  # both lakehouses, merged into one view (see "Several lakes" below)
//   node serve.mjs --open       # ...and open it in the browser
//   node serve.mjs --check      # only check access: exit 0, or exit 2 with what to fix
//   node serve.mjs --port 9000  # another port; --no-check skips the access check
//
// Before serving, it checks that the cloud's CLI is installed, you're signed in, and your identity can
// query the lakehouse (AWS: a region is set and the Athena workgroup is usable; GCP: a project is set and
// the traceforce_lakehouse dataset is queryable), and stops with the fix if not. If the port already has a
// dashboards server, it reuses that one (and opens it with --open) instead of failing.
//
// Every folder here with an api.mjs is a dashboard, served at /<folder>/ and listed on the home page.
// An api.mjs exports:
//   title, description   for the home page
//   order                optional number: lower comes first on the home page (then by folder name)
//   params               { name: { pattern, timestamp?, emptyIsNull? } }: the values its pages may send
//   routes               { name: async (query, { run, runAll, arg }) => json }, served at /<folder>/api/<name>
// run("x", params) runs the folder's queries/x.sql (Athena) or queries/bigquery/x.sql (BigQuery) through
// the skill's athena_query.sh or bq_query.sh, with each {{param}} placeholder replaced by the checked value
// as a SQL literal, and resolves to its rows.
//
// Several lakes: every query runs on each, and the rows are concatenated (the routes merge what needs it,
// such as freshness, findings by id, or a session's parts). A session can be in more than one lake: copied
// whole into both, or continued in a new lake after a move. So for a session an earlier-listed lake has,
// later lakes' queries skip its events inside the time span the earlier lake holds for it (agent_events is
// swapped for a filtered subquery): copies are counted once, and a continued session keeps both parts. List
// the newest, most complete lake first. The spans come from listing each lake's sessions of the last 92
// days, refreshed every 15 minutes. Daily session counts still count a continued session once per lake.
//
// Needs Node 18 or later, and the same credentials as the query script: on AWS, the AWS credentials and
// region of athena_query.sh; on GCP, the gcloud sign-in and project of bq_query.sh
// (TRACEFORCE_LAKEHOUSE_PROJECT, else the gcloud default project). Nothing is written to disk here:
// results go straight to the page. (Athena itself keeps each result in the workgroup's S3 result location,
// and BigQuery in its own temporary result tables, as they do for every query.) The server listens on
// 127.0.0.1 only and runs only the SQL files in each dashboard's queries/. The pages send values, never SQL.
import { execFile, spawn } from "node:child_process";
import { existsSync, readdirSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPTS = join(HERE, "..", "..", "skills", "traceforce-lakehouse", "scripts");
const SHARED = new Set(["dashboard.css", "dashboard.js"]);

// Columns the pages treat as numbers. Empty cells are SQL NULLs ("not reported"), kept distinct from 0.
const NUM = new Set(["sessions", "prompts", "tool_calls", "requests", "calls", "tokens", "live_devices",
  "input_tokens", "output_tokens", "cache_read_tokens", "cost_usd", "findings", "open_findings", "blocks"]);

class BadRequest extends Error {}
class QueryFailed extends Error {}

const argv = process.argv.slice(2);
const flag = name => argv.includes(name);
const option = (name, fallback) => (argv.indexOf(name) >= 0 ? argv[argv.indexOf(name) + 1] : fallback);
const PORT = Number(option("--port", 8765));
const URL_HOME = `http://localhost:${PORT}/`;
const WORKGROUP = "traceforce-lakehouse";
const DATASET = "traceforce_lakehouse";

// The lakehouse's cloud picks the query script, the folder of SQL in its dialect, how a string literal is
// quoted (GoogleSQL has backslash escapes, not doubled quotes), the access check, its events table and the
// query listing its recent session ids.
const ENGINES = {
  aws: { script: "athena_query.sh", queries: "queries", check: checkAws,
    quote: v => "'" + v.replaceAll("'", "''") + "'", events: "agent_events",
    sessionSpans: "SELECT session_id, cast(min(ts) AS varchar) AS t0, cast(max(ts) AS varchar) AS t1 FROM agent_events " +
      "WHERE session_id IS NOT NULL AND ts >= date_add('day', -92, current_date) GROUP BY session_id" },
  gcp: { script: "bq_query.sh", queries: join("queries", "bigquery"), check: checkGcp,
    quote: v => "'" + v.replace(/[\\']/g, "\\$&") + "'", events: `${DATASET}.agent_events`,
    sessionSpans: "SELECT session_id, FORMAT_TIMESTAMP('%F %H:%M:%E6S', min(ts)) AS t0, FORMAT_TIMESTAMP('%F %H:%M:%E6S', max(ts)) AS t1 " +
      `FROM ${DATASET}.agent_events WHERE session_id IS NOT NULL AND ts >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 92 DAY)) GROUP BY session_id` },
};
const CLOUDS = option("--cloud", "aws").split(",");
for (const c of CLOUDS) if (!Object.hasOwn(ENGINES, c)) fail(`Unknown cloud "${c}"`, "Use --cloud aws (Athena), --cloud gcp (BigQuery), or both: --cloud gcp,aws.");
if (new Set(CLOUDS).size !== CLOUDS.length) fail(`--cloud lists a cloud twice`, "List each cloud once, for example --cloud gcp,aws.");
const CLOUD = CLOUDS.join(",");

// RFC 4180 CSV, as Athena writes it: quoted fields may hold commas, doubled quotes and newlines.
function parseCsv(text) {
  const rows = [];
  let row = [], field = "", quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c !== '"') field += c;
      else if (text[i + 1] === '"') { field += '"'; i++; }
      else quoted = false;
    } else if (c === '"') quoted = true;
    else if (c === ",") { row.push(field); field = ""; }
    else if (c === "\n" || c === "\r") {
      if (c === "\r" && text[i + 1] === "\n") i++;
      row.push(field); rows.push(row); row = []; field = "";
    } else field += c;
  }
  if (field || row.length) { row.push(field); rows.push(row); }
  const [head = [], ...body] = rows;
  return body.map(r => Object.fromEntries(head.map((k, j) => {
    const v = r[j] ?? "";
    return [k, v === "" ? null : NUM.has(k) ? Number(v) : v];
  })));
}

// One query on one lake through its script, resolving to its rows. With several lakes, the label names the cloud.
function query(cloud, label, sql) {
  const tag = CLOUDS.length > 1 ? `${label} (${cloud})` : label;
  return new Promise((resolve, reject) => {
    execFile(join(SCRIPTS, ENGINES[cloud].script), [sql], { env: { ...process.env, TRACEFORCE_LAKEHOUSE_MAX_ROWS: "0" },
      timeout: 600_000, maxBuffer: 1 << 30 }, (err, stdout, stderr) => {
      for (const line of stderr.split("\n").filter(Boolean)) console.error(`  ${tag}: ${line}`);
      if (err) {
        const last = stderr.trim().split("\n").pop() || err.message;
        return reject(new QueryFailed(`${tag} failed: ${last}`));
      }
      resolve(parseCsv(stdout));
    });
  });
}

// For each lake, the spans { session_id, t0, t1 } earlier-listed lakes hold of its sessions: events its
// queries skip.
let dupes = null, dupesAt = 0;
function duplicateSessions() {
  if (!dupes || Date.now() - dupesAt > 15 * 60_000) {
    dupesAt = Date.now();
    dupes = Promise.all(CLOUDS.map(c => query(c, "session spans", ENGINES[c].sessionSpans))).then(lists => {
      const earlier = new Map();
      return lists.map(rows => {
        const skip = rows.flatMap(r => earlier.get(r.session_id) || []);
        for (const r of rows) earlier.set(r.session_id, (earlier.get(r.session_id) || []).concat(r));
        return skip;
      });
    });
    dupes.then(skips => CLOUDS.forEach((c, i) => i && console.error(`  ${c}: skipping the spans ${CLOUDS.slice(0, i).join(", ")} already holds of ${skips[i].length} sessions`)),
      () => { dupes = null; });
  }
  return dupes;
}

// The query helpers one dashboard's routes get, bound to its folder and its params.
function helpers(dir, params) {
  // A checked page value as a SQL literal in one engine's dialect.
  function literal(engine, name, value) {
    const spec = params[name];
    if (!spec) throw new BadRequest(`unknown parameter ${name}`);
    if (spec.emptyIsNull && value === "") return "NULL";
    if (!spec.pattern.test(value)) throw new BadRequest(`invalid ${name}`);
    const quoted = engine.quote(value);
    return spec.timestamp ? "TIMESTAMP " + quoted : quoted;
  }
  // The query on every lake, with the rows concatenated in lake order.
  async function run(name, values = {}) {
    const skips = CLOUDS.length > 1 ? await duplicateSessions() : [];
    const parts = await Promise.all(CLOUDS.map(async (cloud, i) => {
      const engine = ENGINES[cloud];
      let sql = await readFile(join(dir, engine.queries, name + ".sql"), "utf8");
      for (const [k, v] of Object.entries(values)) sql = sql.replaceAll(`{{${k}}}`, literal(engine, k, v));
      if (sql.includes("{{")) throw new BadRequest(`${name}.sql needs a parameter that wasn't given`);
      if (skips[i] && skips[i].length) {
        const q = engine.quote;
        const held = skips[i].map(x => `(session_id = ${q(x.session_id)} AND ts BETWEEN TIMESTAMP ${q(x.t0)} AND TIMESTAMP ${q(x.t1)})`);
        const kept = `(SELECT * FROM ${engine.events} WHERE session_id IS NULL OR NOT (${held.join(" OR ")}))`;
        sql = sql.replace(/\b(?:traceforce_lakehouse\.)?agent_events\b/g, kept);
      }
      return query(cloud, name + ".sql", sql);
    }));
    return parts.flat();
  }
  // Several queries at once; Athena and BigQuery run them in parallel.
  async function runAll(jobs) {
    const keys = Object.keys(jobs);
    const results = await Promise.all(keys.map(k => run(...jobs[k])));
    return Object.fromEntries(keys.map((k, i) => [k, results[i]]));
  }
  function arg(q, name) {
    if (!q.has(name)) throw new BadRequest(`missing ${name}`);
    return q.get(name);
  }
  return { run, runAll, arg };
}

const found = [];
for (const ent of readdirSync(HERE, { withFileTypes: true })) {
  const dir = join(HERE, ent.name);
  if (!ent.isDirectory() || !existsSync(join(dir, "api.mjs"))) continue;
  const mod = await import(pathToFileURL(join(dir, "api.mjs")).href);
  found.push([ent.name, { dir, mod, ctx: helpers(dir, mod.params || {}) }]);
}
const rank = ([, { mod }]) => mod.order ?? Infinity;
const DASHBOARDS = new Map(found.sort((a, b) => rank(a) - rank(b) || a[0].localeCompare(b[0])));

const esc = s => String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
function homePage() {
  const cards = [...DASHBOARDS].map(([name, { mod }]) =>
    `<a class="card dash" href="${esc(name)}/"><h2>${esc(mod.title || name)}</h2><p class="sub">${esc(mod.description || "")}</p></a>`);
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>TraceForce Dashboards</title><meta name="traceforce-cloud" content="${CLOUD}">
<link rel="stylesheet" href="shared/dashboard.css"></head>
<body><main><header><h1>TraceForce dashboards</h1><span class="meta">Queried live from your lakehouse</span></header>
<section class="dashes">${cards.join("")}</section></main></body></html>`;
}

function send(res, status, type, body, extra = {}) {
  res.writeHead(status, { "Content-Type": type, "Cache-Control": "no-store", "Content-Length": Buffer.byteLength(body), ...extra });
  res.end(body);
}

// ---------- access checks ----------
// Each step that fails says what to do. Exits 2 so a caller (such as the /dashboards command) can tell
// "fix your setup" from a crash.
function cli(cmd, args) {
  return new Promise(resolve => execFile(cmd, args, { timeout: 30_000 }, (err, stdout, stderr) =>
    resolve({ ok: !err, missing: err && err.code === "ENOENT", stdout: stdout.trim(), stderr: (stderr || (err && err.message) || "").trim() })));
}
const aws = args => cli("aws", args);
function fail(what, fix) {
  console.error(`✗ ${what}\n  ${fix.split("\n").join("\n  ")}`);
  process.exit(2);
}
async function checkAws() {
  const profile = process.env.AWS_PROFILE;
  const p = profile ? ` --profile ${profile}` : "";
  if (Number(process.versions.node.split(".")[0]) < 18) fail(`Node ${process.versions.node} is too old`, "Install Node 18 or later.");

  if ((await aws(["--version"])).missing)
    fail("The AWS CLI isn't installed", "Install AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html");
  if (profile && !(await aws(["configure", "list-profiles"])).stdout.split("\n").includes(profile))
    fail(`AWS profile "${profile}" doesn't exist`, "Set AWS_PROFILE to one of the profiles in ~/.aws/config (aws configure list-profiles).");
  const region = process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION || (await aws(["configure", "get", "region"])).stdout;
  if (!region) fail("No AWS region is set", `Set the lakehouse's region, for example: AWS_REGION=us-east-1${profile ? ` AWS_PROFILE=${profile}` : ""}\nor save it in your profile: aws configure set region us-east-1${p}`);

  const id = await aws(["sts", "get-caller-identity", "--output", "json"]);
  if (!id.ok) {
    const e = id.stderr;
    if (/InvalidClientTokenId|SignatureDoesNotMatch/i.test(e))
      fail("The AWS access keys in your environment are invalid", "Replace AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY, or unset them to use your profile.");
    if (/expired|ExpiredToken|Token has expired|refresh failed|SSO session|SSO Token/i.test(e))
      fail("You're not signed in to AWS, or your session has expired", `Sign in: aws sso login${p}`);
    if (/Unable to locate credentials|NoCredentialProviders|no credentials/i.test(e))
      fail("No AWS credentials found", `Sign in (aws sso login${p || " --profile <name>"}, or aws configure), or set AWS_PROFILE to a profile that has access to the lakehouse.`);
    fail("AWS rejected your credentials", e.split("\n").pop());
  }
  const who = JSON.parse(id.stdout);
  console.error(`✓ Signed in to AWS as ${who.Arn} (account ${who.Account}, region ${region})`);

  const wg = await aws(["athena", "get-work-group", "--work-group", WORKGROUP, "--region", region, "--output", "json"]);
  if (!wg.ok) {
    const e = wg.stderr;
    if (/AccessDenied|not authorized/i.test(e))
      fail(`${who.Arn} can't use the lakehouse's Athena workgroup`, `Attach the lakehouse module's read-only query_policy_json to this identity, or switch AWS_PROFILE to one that has it.`);
    if (/not found|InvalidRequestException/i.test(e))
      fail(`No "${WORKGROUP}" Athena workgroup in account ${who.Account}, region ${region}`, "Point AWS_PROFILE and AWS_REGION at the account and region where the lakehouse is deployed.");
    fail("Couldn't reach Athena", e.split("\n").pop());
  }
  console.error(`✓ Lakehouse workgroup "${WORKGROUP}" is reachable`);
}

async function checkGcp() {
  if (Number(process.versions.node.split(".")[0]) < 18) fail(`Node ${process.versions.node} is too old`, "Install Node 18 or later.");

  if ((await cli("gcloud", ["--version"])).missing)
    fail("The gcloud CLI isn't installed", "Install the Google Cloud CLI: https://cloud.google.com/sdk/docs/install");
  if ((await cli("bq", ["version"])).missing)
    fail("The bq CLI isn't installed", "Install it with the Google Cloud CLI: gcloud components install bq");
  let project = process.env.TRACEFORCE_LAKEHOUSE_PROJECT;
  if (!project) project = (await cli("gcloud", ["config", "get-value", "project"])).stdout;
  if (!project || project === "(unset)")
    fail("No GCP project is set", "Set the lakehouse's project: gcloud config set project <id>\nor TRACEFORCE_LAKEHOUSE_PROJECT=<id> for this server only.");

  const account = (await cli("gcloud", ["config", "get-value", "account"])).stdout;
  if (!account || account === "(unset)") fail("You're not signed in to gcloud", "Sign in: gcloud auth login");
  const token = await cli("gcloud", ["auth", "print-access-token"]);
  if (!token.ok) {
    if (/reauth|expired|invalid_grant|refresh/i.test(token.stderr))
      fail(`Your gcloud sign-in for ${account} has expired`, "Sign in again: gcloud auth login");
    fail("gcloud rejected your credentials", token.stderr.split("\n").pop());
  }
  console.error(`✓ Signed in to gcloud as ${account} (project ${project})`);

  // A dry run plans a query without running it, so it proves the identity can both start query jobs in
  // the project and read the dataset, at no cost.
  const dry = await cli("bq", ["query", `--project_id=${project}`, "--use_legacy_sql=false", "--dry_run",
    `SELECT ts FROM ${DATASET}.agent_events LIMIT 1`]);
  if (!dry.ok) {
    const e = `${dry.stdout}\n${dry.stderr}`.trim();
    if (/Not found: Dataset|Not found: Table|was not found/i.test(e))
      fail(`No "${DATASET}" dataset in project ${project}`, "Point the project at the one the lakehouse is deployed in: gcloud config set project <id>\nor TRACEFORCE_LAKEHOUSE_PROJECT=<id>.");
    if (/bigquery\.jobs\.create/i.test(e))
      fail(`${account} can't run BigQuery queries in project ${project}`, "Grant it roles/bigquery.jobUser on the project.");
    if (/Access Denied|permission|denied/i.test(e))
      fail(`${account} can't read the lakehouse's "${DATASET}" dataset`, "Add it to the module's query_members (roles/bigquery.dataViewer and connectionUser), or sign in as an identity that has them.");
    if (/reauth|credentials|login/i.test(e))
      fail("bq couldn't use your gcloud sign-in", "Sign in again: gcloud auth login");
    fail("Couldn't reach BigQuery", e.split("\n").pop());
  }
  console.error(`✓ Lakehouse dataset "${DATASET}" is queryable`);
}

// ---------- browser ----------
function openBrowser(url) {
  const [cmd, args] = process.platform === "darwin" ? ["open", [url]]
    : process.platform === "win32" ? ["cmd", ["/c", "start", "", url]] : ["xdg-open", [url]];
  const child = spawn(cmd, args, { detached: true, stdio: "ignore" });
  child.on("error", () => console.error(`Open ${url} in your browser.`));
  child.unref();
}

// An earlier server on this port: reuse it if it's ours and queries the same cloud, otherwise say what's
// in the way.
async function portInUse() {
  let page = "";
  try { page = await (await fetch(URL_HOME)).text(); } catch (_) { /* not HTTP */ }
  const ours = page.includes("<title>TraceForce Dashboards</title>");
  const other = ours && (page.match(/<meta name="traceforce-cloud" content="([\w,]+)">/) || [, "aws"])[1];
  if (ours && other !== CLOUD)
    fail(`Port ${PORT} already has dashboards for --cloud ${other}`, `Stop that server, or pick another port: node serve.mjs --cloud ${CLOUD} --port ${PORT + 1}${flag("--open") ? " --open" : ""}`);
  if (!ours) fail(`Port ${PORT} is used by another program`, `Pick another port: node serve.mjs${CLOUD === "aws" ? "" : ` --cloud ${CLOUD}`} --port ${PORT + 1}${flag("--open") ? " --open" : ""}`);
  console.error(`Dashboards are already running at ${URL_HOME}`);
  if (flag("--open")) openBrowser(URL_HOME);
  process.exit(0);
}

if (!flag("--no-check")) for (const c of CLOUDS) await ENGINES[c].check();
if (flag("--check")) process.exit(0);

const server = createServer(async (req, res) => {
  // A page on another site can't reach this server through a DNS name that points at 127.0.0.1.
  if (![`localhost:${PORT}`, `127.0.0.1:${PORT}`].includes(req.headers.host)) return send(res, 403, "text/plain", "forbidden host");
  if (req.method !== "GET") return send(res, 405, "text/plain", "method not allowed");
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const [, first = "", second = "", third = "", ...rest] = url.pathname.split("/");
  console.error(`${req.method} ${url.pathname}`);

  if (!first) return send(res, 200, "text/html; charset=utf-8", homePage());
  if (first === "shared" && SHARED.has(second) && !third)
    return send(res, 200, second.endsWith(".css") ? "text/css" : "text/javascript", await readFile(join(HERE, "shared", second)));
  const dash = DASHBOARDS.get(first);
  if (!dash) return send(res, 404, "text/plain", "not found");
  if (url.pathname === `/${first}`) return send(res, 301, "text/plain", "", { Location: `/${first}/` });
  if (!second || (second === "index.html" && !third))
    return send(res, 200, "text/html; charset=utf-8", await readFile(join(dash.dir, "index.html")));
  const route = second === "api" && !rest.length && Object.hasOwn(dash.mod.routes, third) && dash.mod.routes[third];
  if (!route) return send(res, 404, "text/plain", "not found");
  let status = 200, body;
  try {
    body = await route(url.searchParams, dash.ctx);
  } catch (e) {
    status = e instanceof BadRequest ? 400 : 502;
    body = { error: e instanceof BadRequest || e instanceof QueryFailed ? e.message : "query failed: " + e.message };
    console.error(`  -> ${status} ${body.error}`);
  }
  send(res, status, "application/json", JSON.stringify(body));
});
server.on("error", e => (e.code === "EADDRINUSE" ? portInUse() : fail("The server couldn't start", e.message)));
server.listen(PORT, "127.0.0.1", () => {
  console.error(`Serving on ${URL_HOME} (Ctrl-C to stop)`);
  for (const name of DASHBOARDS.keys()) console.error(`  ${URL_HOME}${name}/`);
  if (flag("--open")) openBrowser(URL_HOME);
});
