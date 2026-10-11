#!/usr/bin/env node
// Serve the TraceForce lakehouse dashboards, querying the lakehouse (AWS / Athena) live.
//
//   node serve.mjs              # check AWS access, then serve http://localhost:8765
//   node serve.mjs --open       # ...and open it in the browser
//   node serve.mjs --check      # only check AWS access: exit 0, or exit 2 with what to fix
//   node serve.mjs --port 9000  # another port; --no-check skips the AWS check
//
// Before serving, it checks that the AWS CLI is installed, a region is set, you're signed in, and your
// identity can use the lakehouse's Athena workgroup, and stops with the fix if not. If the port already
// has a dashboards server, it reuses that one (and opens it with --open) instead of failing.
//
// Every folder here with an api.mjs is a dashboard, served at /<folder>/ and listed on the home page.
// An api.mjs exports:
//   title, description   for the home page
//   order                optional number: lower comes first on the home page (then by folder name)
//   params               { name: { pattern, timestamp?, emptyIsNull? } }: the values its pages may send
//   routes               { name: async (query, { run, runAll, arg }) => json }, served at /<folder>/api/<name>
// run("x", params) runs the folder's queries/x.sql through the skill's athena_query.sh, with each
// {{param}} placeholder replaced by the checked value as a SQL literal, and resolves to its rows.
//
// Needs Node 18 or later, and the same AWS credentials and region as athena_query.sh. Nothing is written
// to disk here: results go straight to the page. (Athena itself keeps each result in the workgroup's S3
// result location, as it does for every query.) The server listens on 127.0.0.1 only and runs only the
// SQL files in each dashboard's queries/. The pages send values, never SQL.
import { execFile, spawn } from "node:child_process";
import { existsSync, readdirSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const QUERY = join(HERE, "..", "..", "skills", "traceforce-lakehouse", "scripts", "athena_query.sh");
const SHARED = new Set(["dashboard.css", "dashboard.js"]);

// Columns the pages treat as numbers. Empty cells are SQL NULLs ("not reported"), kept distinct from 0.
const NUM = new Set(["sessions", "prompts", "tool_calls", "requests", "calls", "tokens", "live_devices",
  "input_tokens", "output_tokens", "cache_read_tokens", "cost_usd", "findings", "open_findings", "blocks"]);

class BadRequest extends Error {}
class QueryFailed extends Error {}

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

// The query helpers one dashboard's routes get, bound to its folder and its params.
function helpers(dir, params) {
  // A checked page value as a SQL literal.
  function literal(name, value) {
    const spec = params[name];
    if (!spec) throw new BadRequest(`unknown parameter ${name}`);
    if (spec.emptyIsNull && value === "") return "NULL";
    if (!spec.pattern.test(value)) throw new BadRequest(`invalid ${name}`);
    const quoted = "'" + value.replaceAll("'", "''") + "'";
    return spec.timestamp ? "TIMESTAMP " + quoted : quoted;
  }
  async function run(name, values = {}) {
    let sql = await readFile(join(dir, "queries", name + ".sql"), "utf8");
    for (const [k, v] of Object.entries(values)) sql = sql.replaceAll(`{{${k}}}`, literal(k, v));
    if (sql.includes("{{")) throw new BadRequest(`${name}.sql needs a parameter that wasn't given`);
    return new Promise((resolve, reject) => {
      execFile(QUERY, [sql], { env: { ...process.env, TRACEFORCE_LAKEHOUSE_MAX_ROWS: "0" },
        timeout: 600_000, maxBuffer: 1 << 30 }, (err, stdout, stderr) => {
        for (const line of stderr.split("\n").filter(Boolean)) console.error(`  ${name}: ${line}`);
        if (err) {
          const last = stderr.trim().split("\n").pop() || err.message;
          return reject(new QueryFailed(`${name}.sql failed: ${last}`));
        }
        resolve(parseCsv(stdout));
      });
    });
  }
  // Several queries at once; Athena runs them in parallel.
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
<title>TraceForce Dashboards</title><link rel="stylesheet" href="shared/dashboard.css"></head>
<body><main><header><h1>TraceForce dashboards</h1><span class="meta">Queried live from your lakehouse</span></header>
<section class="dashes">${cards.join("")}</section></main></body></html>`;
}

function send(res, status, type, body, extra = {}) {
  res.writeHead(status, { "Content-Type": type, "Cache-Control": "no-store", "Content-Length": Buffer.byteLength(body), ...extra });
  res.end(body);
}

const argv = process.argv.slice(2);
const flag = name => argv.includes(name);
const portFlag = argv.indexOf("--port");
const PORT = portFlag >= 0 ? Number(argv[portFlag + 1]) : 8765;
const URL_HOME = `http://localhost:${PORT}/`;
const WORKGROUP = "traceforce-lakehouse";

// ---------- AWS access check ----------
// Each step that fails says what to do. Exits 2 so a caller (such as the /dashboards command) can tell
// "fix your setup" from a crash.
function aws(args) {
  return new Promise(resolve => execFile("aws", args, { timeout: 30_000 }, (err, stdout, stderr) =>
    resolve({ ok: !err, missing: err && err.code === "ENOENT", stdout: stdout.trim(), stderr: (stderr || (err && err.message) || "").trim() })));
}
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

// ---------- browser ----------
function openBrowser(url) {
  const [cmd, args] = process.platform === "darwin" ? ["open", [url]]
    : process.platform === "win32" ? ["cmd", ["/c", "start", "", url]] : ["xdg-open", [url]];
  const child = spawn(cmd, args, { detached: true, stdio: "ignore" });
  child.on("error", () => console.error(`Open ${url} in your browser.`));
  child.unref();
}

// An earlier server on this port: reuse it if it's ours, otherwise say what's in the way.
async function portInUse() {
  let ours = false;
  try { ours = (await (await fetch(URL_HOME)).text()).includes("<title>TraceForce Dashboards</title>"); } catch (_) { /* not HTTP */ }
  if (!ours) fail(`Port ${PORT} is used by another program`, `Pick another port: node serve.mjs --port ${PORT + 1}${flag("--open") ? " --open" : ""}`);
  console.error(`Dashboards are already running at ${URL_HOME}`);
  if (flag("--open")) openBrowser(URL_HOME);
  process.exit(0);
}

if (!flag("--no-check")) await checkAws();
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
