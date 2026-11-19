#!/usr/bin/env node
// Serve the TraceForce lakehouse dashboards, querying the lakehouse live: Athena on AWS, BigQuery on GCP,
// Databricks SQL on Azure Databricks, Snowflake on AWS or Azure.
//
//   node serve.mjs              # check AWS access, then serve http://localhost:8765
//   node serve.mjs --cloud gcp  # the same for a GCP (BigQuery) lakehouse (default: --cloud aws)
//   node serve.mjs --cloud databricks  # the same for an Azure Databricks lakehouse
//   node serve.mjs --cloud snowflake   # the same for a Snowflake lakehouse (on AWS or Azure)
//   node serve.mjs --cloud gcp,aws  # both lakehouses, merged into one view (see "Several lakes" below)
//   node serve.mjs --open       # ...and open it in the browser
//   node serve.mjs --check      # only check access: exit 0, or exit 2 with what to fix
//   node serve.mjs --port 9000  # another port; --no-check skips the access check
//
// Before serving, it checks that the cloud's CLI is installed, you're signed in, and your identity can
// query the lakehouse (AWS: a region is set and the Athena workgroup is usable; GCP: a project is set and
// the traceforce_lakehouse dataset is queryable; Databricks: the workspace and query warehouse are set and
// a small query on the lakehouse succeeds; Snowflake: the connector and credentials are in place and a small
// query on the lakehouse succeeds as the reader role, resuming the query warehouse if suspended, billed for at least
// 60 s), and stops with the fix if not. If the port already has a dashboards server, it reuses that one (and
// opens it with --open) instead of failing.
//
// Every folder here with an api.mjs is a dashboard, served at /<folder>/ and listed on the home page.
// An api.mjs exports:
//   title, description   for the home page
//   order                optional number: lower comes first on the home page (then by folder name)
//   params               { name: { pattern, timestamp?, emptyIsNull? } }: the values its pages may send
//   routes               { name: async (query, { run, runAll, arg }) => json }, served at /<folder>/api/<name>
// run("x", params) runs the folder's queries/x.sql (Athena), queries/bigquery/x.sql (BigQuery),
// queries/databricks/x.sql (Databricks) or queries/snowflake/x.sql (Snowflake) through the skill's
// athena_query.sh, bq_query.sh, databricks_query.sh or snowflake_query.sh, with each {{param}} placeholder
// replaced by the checked value as a SQL literal, and resolves to its rows. The per-engine SQL logic is in
// engines.mjs.
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
// (TRACEFORCE_LAKEHOUSE_PROJECT, else the gcloud default project); on Azure Databricks, python3 and the
// settings and sign-in of databricks_query.sh (DATABRICKS_HOST, TRACEFORCE_LAKEHOUSE_WAREHOUSE_ID, and
// az login, a Databricks CLI login or a service principal's DATABRICKS_CLIENT_ID/SECRET); on Snowflake, python3
// with snowflake-connector-python and the credentials of snowflake_query.sh (all five SNOWFLAKE_* variables,
// or none and a connections.toml connection) for a user holding the reader role (queries run on the
// query warehouse, named at sign-in, so no default warehouse is needed). Nothing is written to disk here:
// results go straight to the page. (Athena itself keeps each result in the workgroup's S3 result location,
// and BigQuery in its own temporary result tables, as they do for every query.) The server listens on
// 127.0.0.1 only and runs only the SQL files in each dashboard's queries/. The pages send values, never SQL.
import { execFile, spawn } from "node:child_process";
import { existsSync, readdirSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { BadRequest, DATASET, ENGINES, buildSql, classifySnowflakeError, parseCsv, scriptMessages } from "./engines.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPTS = join(HERE, "..", "..", "skills", "traceforce-lakehouse", "scripts");
const SHARED = new Set(["dashboard.css", "dashboard.js"]);

class QueryFailed extends Error {}

const argv = process.argv.slice(2);
const flag = name => argv.includes(name);
const option = (name, fallback) => (argv.indexOf(name) >= 0 ? argv[argv.indexOf(name) + 1] : fallback);
const PORT = Number(option("--port", 8765));
const URL_HOME = `http://localhost:${PORT}/`;
const WORKGROUP = "traceforce-lakehouse";
const CHECKS = { aws: checkAws, gcp: checkGcp, databricks: checkDatabricks, snowflake: checkSnowflake };

const CLOUDS = option("--cloud", "aws").split(",");
for (const c of CLOUDS) if (!Object.hasOwn(ENGINES, c)) fail(`Unknown cloud "${c}"`, "Use --cloud aws (Athena), --cloud gcp (BigQuery), --cloud databricks (Azure Databricks), --cloud snowflake (Snowflake on AWS or Azure), or several: --cloud gcp,aws.");
if (new Set(CLOUDS).size !== CLOUDS.length) fail(`--cloud lists a cloud twice`, "List each cloud once, for example --cloud gcp,aws.");
const CLOUD = CLOUDS.join(",");

// A table or column the dashboards read that the lake lacks: its Terraform module predates them. Snowflake:
// "Object '"<table>"' does not exist or not authorized" and "invalid identifier '"<column>"'" (the reader role
// is granted every table in the schema, so a missing table there is an older module too).
const MISSING_SCHEMA = /TABLE_NOT_FOUND|COLUMN_NOT_FOUND|Table .* does not exist|Not found: Table|Unrecognized name|TABLE_OR_VIEW_NOT_FOUND|UNRESOLVED_COLUMN|Object '"[a-z_]+"' does not exist or not authorized|invalid identifier '"[a-z_]+"'/;
const UPGRADE_MODULE = "Your lakehouse is on an older TraceForce module than these dashboards. " +
  "Update the module's ?ref= to the latest release, then run terraform init -upgrade and terraform apply.";

// One query on one lake through its script, resolving to its rows. With several lakes, the label names the cloud.
function query(cloud, label, sql) {
  const tag = CLOUDS.length > 1 ? `${label} (${cloud})` : label;
  return new Promise((resolve, reject) => {
    // TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT: the Databricks and Snowflake scripts cancel a statement after
    // 300 s by default; give them nearly the 600 s this waits, so it ends with the warehouse's message rather
    // than being killed. (The Athena and BigQuery scripts set no time limit of their own.)
    execFile(join(SCRIPTS, ENGINES[cloud].script), [sql], { env: { ...process.env, TRACEFORCE_LAKEHOUSE_MAX_ROWS: "0",
      TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT: "590" },
      timeout: 600_000, maxBuffer: 1 << 30 }, (err, stdout, stderr) => {
      const lines = scriptMessages(stderr);
      for (const line of lines) console.error(`  ${tag}: ${line}`);
      if (err) {
        if (MISSING_SCHEMA.test(stderr)) return reject(new QueryFailed(CLOUDS.length > 1 ? `${cloud}: ${UPGRADE_MODULE}` : UPGRADE_MODULE));
        const last = (lines.length && ENGINES[cloud].errorLine(lines)) || err.message;
        return reject(new QueryFailed(`${tag} failed: ${last}`));
      }
      resolve(parseCsv(stdout, { lowerHeader: ENGINES[cloud].lowerHeader, label: tag, warn: m => console.error(`  ${m}`) }));
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
  // The query on every lake, with the rows concatenated in lake order.
  async function run(name, values = {}) {
    const skips = CLOUDS.length > 1 ? await duplicateSessions() : [];
    const parts = await Promise.all(CLOUDS.map(async (cloud, i) => {
      const engine = ENGINES[cloud];
      const file = join(dir, engine.queries, name + ".sql");
      if (!existsSync(file)) throw new QueryFailed(`${name}.sql isn't available for --cloud ${cloud} yet`);
      const text = await readFile(file, "utf8");
      return query(cloud, name + ".sql", buildSql(engine, text, params, values, skips[i] || [], name));
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

async function checkDatabricks() {
  if (Number(process.versions.node.split(".")[0]) < 18) fail(`Node ${process.versions.node} is too old`, "Install Node 18 or later.");

  if ((await cli("python3", ["--version"])).missing)
    fail("python3 isn't installed", "The Databricks query script needs it: install Python 3.8 or later.");
  const host = (process.env.DATABRICKS_HOST || "").trim();
  if (!host)
    fail("DATABRICKS_HOST isn't set", "Set it to the lakehouse module's databricks_workspace_url output, for example:\nexport DATABRICKS_HOST=adb-<id>.<n>.azuredatabricks.net");
  if (!(process.env.TRACEFORCE_LAKEHOUSE_WAREHOUSE_ID || "").trim())
    fail("TRACEFORCE_LAKEHOUSE_WAREHOUSE_ID isn't set", "Set it to the lakehouse module's query_warehouse_id output (the warehouse readers use), for example:\nexport TRACEFORCE_LAKEHOUSE_WAREHOUSE_ID=<id>");
  const site = "https://" + host.replace(/^https?:\/\//i, "").split(/[/?#]/)[0];

  // One small query, through the same script the dashboards use, names the identity and proves it can
  // read the lakehouse. It may start the query warehouse.
  const probe = await new Promise(resolve => execFile(join(SCRIPTS, "databricks_query.sh"),
    [`SELECT current_user() AS who, (SELECT count(*) FROM (SELECT 1 FROM ${DATASET}.traceforce.agent_events LIMIT 1)) AS readable`],
    { timeout: 300_000 }, (err, stdout, stderr) => resolve({ ok: !err, stdout, stderr: (stderr || (err && err.message) || "").trim() })));
  if (!probe.ok) {
    const e = probe.stderr;
    // The script prints its error first; lines it adds after it (a cancelled statement) start with "-- ".
    const first = e.split("\n").find(l => l.trim() && !l.startsWith("-- ")) || e;
    if (/check DATABRICKS_CLIENT_ID/.test(e))
      fail("Databricks refused the service principal's credentials", "Check DATABRICKS_CLIENT_ID and DATABRICKS_CLIENT_SECRET: the service principal's application ID and a Databricks OAuth secret generated for it in Databricks (not an Entra client secret).");
    if (/authentication failed|no sign-in found/.test(e))
      fail("You're not signed in to Databricks", `Sign in: az login (in the tenant of the workspace)\nor: databricks auth login --host ${site}\nor set DATABRICKS_CLIENT_ID and DATABRICKS_CLIENT_SECRET for a reader service principal.`);
    if (/check TRACEFORCE_LAKEHOUSE_WAREHOUSE_ID/.test(e))
      fail(`No warehouse "${process.env.TRACEFORCE_LAKEHOUSE_WAREHOUSE_ID}" in workspace ${site}`, "Set TRACEFORCE_LAKEHOUSE_WAREHOUSE_ID to the lakehouse module's query_warehouse_id output.");
    if (/permission denied|reader inputs|PERMISSION_DENIED|INSUFFICIENT_PERMISSIONS/.test(e))
      fail("You can't read the lakehouse", "Ask your admin to list you in the lakehouse module's reader inputs (reader_user_names, reader_group_names or reader_service_principal_names) and give you the Databricks SQL access entitlement.");
    if (/TABLE_OR_VIEW_NOT_FOUND|SCHEMA_NOT_FOUND|NO_SUCH_CATALOG/.test(e))
      fail(`No "${DATASET}" lakehouse in workspace ${site}`, "Point DATABRICKS_HOST and TRACEFORCE_LAKEHOUSE_WAREHOUSE_ID at the same lakehouse deployment (the module's databricks_workspace_url and query_warehouse_id outputs). If they already are, ask your admin to list you as a reader.");
    if (/cannot reach|unexpected reply/.test(e))
      fail(`Couldn't reach the Databricks workspace ${site}`, `Check DATABRICKS_HOST: ${first.replace(/ \(check DATABRICKS_HOST\)$/, "")}`);
    fail("Databricks refused the query", first);
  }
  const who = parseCsv(probe.stdout)[0]?.who || "an unknown identity";
  console.error(`✓ Signed in to Databricks as ${who} (workspace ${site})`);
  console.error(`✓ Lakehouse catalog "${DATASET}" is queryable on warehouse ${process.env.TRACEFORCE_LAKEHOUSE_WAREHOUSE_ID.trim()}`);
}

const SNOWFLAKE_VARS = ["SNOWFLAKE_ORGANIZATION_NAME", "SNOWFLAKE_ACCOUNT_NAME", "SNOWFLAKE_USER", "SNOWFLAKE_AUTHENTICATOR", "SNOWFLAKE_PRIVATE_KEY"];
async function checkSnowflake() {
  if (Number(process.versions.node.split(".")[0]) < 18) fail(`Node ${process.versions.node} is too old`, "Install Node 18 or later.");

  if ((await cli("python3", ["--version"])).missing)
    fail("python3 isn't installed", "The Snowflake query script needs it: install Python 3.");
  const imp = await cli("python3", ["-c", "import snowflake.connector"]);
  if (!imp.ok) {
    if (/No module named/.test(imp.stderr))
      fail("snowflake-connector-python isn't installed", "Install it for the python3 on your PATH: python3 -m pip install snowflake-connector-python");
    fail("snowflake-connector-python doesn't import", imp.stderr.split("\n").pop());
  }
  // The script takes all five variables (key-pair sign-in) or none (a connections.toml connection), with
  // its rules: a variable counts as set when it isn't empty, and the authenticator compares uppercased.
  const missing = SNOWFLAKE_VARS.filter(v => !process.env[v]);
  if (missing.length && missing.length < SNOWFLAKE_VARS.length)
    fail(`Only some SNOWFLAKE_* variables are set: missing ${missing.join(", ")}`, "Set all five for key-pair sign-in, or unset all five to use a connections.toml connection.");
  if (!missing.length && process.env.SNOWFLAKE_AUTHENTICATOR.toUpperCase() !== "SNOWFLAKE_JWT")
    fail(`SNOWFLAKE_AUTHENTICATOR is ${process.env.SNOWFLAKE_AUTHENTICATOR}`, "With the five SNOWFLAKE_* variables, set SNOWFLAKE_AUTHENTICATOR=SNOWFLAKE_JWT (key-pair sign-in), or unset all five to use a connections.toml connection (which can use SSO).");
  const via = missing.length ? "your connections.toml connection" : "the SNOWFLAKE_* variables";

  // One small query, through the same script the dashboards use, names the identity and proves it can read
  // the lakehouse as the reader role.
  const probe = await new Promise(resolve => execFile(join(SCRIPTS, "snowflake_query.sh"),
    ['SELECT CURRENT_USER() AS "who", CURRENT_ORGANIZATION_NAME() || \'-\' || CURRENT_ACCOUNT_NAME() AS "account", ' +
      'CURRENT_ROLE() AS "role", (SELECT COUNT(*) FROM (SELECT 1 FROM "agent_events" LIMIT 1)) AS "readable"'],
    { timeout: 300_000 }, (err, stdout, stderr) => resolve({ ok: !err, stdout, stderr: (stderr || (err && err.message) || "").trim() })));
  if (!probe.ok) {
    const { what, fix } = classifySnowflakeError(scriptMessages(probe.stderr).join("\n") || probe.stderr, via);
    fail(what, fix);
  }
  const row = parseCsv(probe.stdout)[0] || {};
  console.error(`✓ Signed in to Snowflake as ${row.who || "an unknown user"} (account ${row.account || "unknown"})`);
  console.error(`✓ Lakehouse "${DATASET}" is queryable as role ${row.role || "unknown"}`);
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

if (!flag("--no-check")) for (const c of CLOUDS) await CHECKS[c]();
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
