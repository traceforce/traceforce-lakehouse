#!/usr/bin/env node
// Serve the TraceForce lakehouse dashboards, querying the lakehouse (AWS / Athena) live.
//
//   node serve.mjs              # then open http://localhost:8765
//   node serve.mjs --port 9000
//
// Every folder here with an api.mjs is a dashboard, served at /<folder>/ and listed on the home page.
// An api.mjs exports:
//   title, description   for the home page
//   params               { name: { pattern, timestamp?, emptyIsNull? } }: the values its pages may send
//   routes               { name: async (query, { run, runAll, arg }) => json }, served at /<folder>/api/<name>
// run("x", params) runs the folder's queries/x.sql through the skill's athena_query.sh, with each
// {{param}} placeholder replaced by the checked value as a SQL literal, and resolves to its rows.
//
// Needs Node 18 or later, and the same AWS credentials and region as athena_query.sh. Nothing is written
// to disk here: results go straight to the page. (Athena itself keeps each result in the workgroup's S3
// result location, as it does for every query.) The server listens on 127.0.0.1 only and runs only the
// SQL files in each dashboard's queries/. The pages send values, never SQL.
import { execFile } from "node:child_process";
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

const DASHBOARDS = new Map();
for (const ent of readdirSync(HERE, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
  const dir = join(HERE, ent.name);
  if (!ent.isDirectory() || !existsSync(join(dir, "api.mjs"))) continue;
  const mod = await import(pathToFileURL(join(dir, "api.mjs")).href);
  DASHBOARDS.set(ent.name, { dir, mod, ctx: helpers(dir, mod.params || {}) });
}

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

const portFlag = process.argv.indexOf("--port");
const PORT = portFlag > 0 ? Number(process.argv[portFlag + 1]) : 8765;

createServer(async (req, res) => {
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
}).listen(PORT, "127.0.0.1", () => {
  console.error(`Serving on http://localhost:${PORT} (Ctrl-C to stop)`);
  for (const name of DASHBOARDS.keys()) console.error(`  http://localhost:${PORT}/${name}/`);
});
