#!/usr/bin/env node
// The dashboards' per-engine SQL logic (examples/dashboards/engines.mjs) and the Snowflake queries' static
// rules, offline: no server, no cloud. The Snowflake cases run the real snowflake_query.sh with a partial
// SNOWFLAKE_* set, so its read-only scan runs and then it stops before connecting.
//
//   node tests/dashboards/test_engines.mjs            # needs Node 18 or later and bash
//   node tests/dashboards/test_engines.mjs --update   # rewrite engine_sql.sha256.json after a deliberate SQL change
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const DASH = join(ROOT, "examples", "dashboards");
const SCRIPT = join(ROOT, "skills", "traceforce-lakehouse", "scripts", "snowflake_query.sh");
const FIXTURES = join(ROOT, "tests", "dashboards", "fixtures");
const SHA_FILE = join(ROOT, "tests", "dashboards", "engine_sql.sha256.json");
const { BadRequest, ENGINES, buildSql, classifySnowflakeError, literal, parseCsv, scriptMessages, snowflakeError } =
  await import(join(DASH, "engines.mjs"));
const sf = ENGINES.snowflake;

const dashboards = [];
for (const name of readdirSync(DASH).sort()) {
  if (!existsSync(join(DASH, name, "api.mjs"))) continue;
  dashboards.push({ name, dir: join(DASH, name), params: (await import(join(DASH, name, "api.mjs"))).params });
}
const sqlFiles = (dir, engine) => (existsSync(join(dir, engine.queries)) ?
  readdirSync(join(dir, engine.queries)).filter(f => f.endsWith(".sql")).sort() : []);

// snowflake_query.sh on one statement, stopped at the credentials step: returns its stderr.
function scan(sql) {
  try {
    execFileSync(SCRIPT, [sql], { env: { PATH: process.env.PATH, HOME: process.env.HOME, SNOWFLAKE_USER: "x" }, stdio: ["ignore", "ignore", "pipe"] });
    return "";
  } catch (e) { return String(e.stderr); }
}
const passedScan = err => err.includes("partial key-pair env var set") && !err.includes("refusing to run");

// ---------- the existing engines' SQL is unchanged ----------
// Two sets of sample values for every placeholder, a NULL variant where a parameter allows it, and a skip
// list whose ids need escaping (a quote and backslash; characters the Databricks script refuses). The fingerprints were taken from serve.mjs before the engine code moved
// to engines.mjs; a deliberate change to an engine's SQL regenerates them with --update.
const SAMPLE = { person: "jane.doe@example.com", agent: "claude_code", session_id: "sess-1:abc.def",
  since: "2026-11-01 00:00:00.123456", until: "2026-11-02 23:59:59" };
const ALT = { person: "x_y%z+w@sub.example.com", agent: "cursor", session_id: "a.b:c-d_e",
  since: "2026-11-01 00:00:00", until: "2026-11-02 23:59:59.123456789" };
const SKIPS = [{ session_id: "s1", t0: "2026-11-01 00:00:00.000000", t1: "2026-11-01 01:00:00.000000" },
  { session_id: "it's\\odd", t0: "2026-10-01 00:00:00", t1: "2026-10-02 00:00:00.5" },
  { session_id: "ctl\u2028\u000b\u0085>x", t0: "2026-09-01 00:00:00.1", t1: "2026-09-01 00:00:01" }];
function fingerprints() {
  const out = {};
  for (const { name, dir, params } of dashboards) for (const cloud of ["aws", "gcp", "databricks"]) {
    const engine = ENGINES[cloud];
    for (const f of sqlFiles(dir, engine)) {
      const text = readFileSync(join(dir, engine.queries, f), "utf8");
      const names = [...new Set([...text.matchAll(/\{\{(\w+)\}\}/g)].map(m => m[1]))];
      const variants = { base: Object.fromEntries(names.map(n => [n, SAMPLE[n]])), alt: Object.fromEntries(names.map(n => [n, ALT[n]])) };
      if (names.some(n => params[n]?.emptyIsNull))
        variants.nulls = Object.fromEntries(names.map(n => [n, params[n]?.emptyIsNull ? "" : SAMPLE[n]]));
      for (const [v, values] of Object.entries(variants)) for (const skips of [[], SKIPS])
        out[`${name}/${f}/${cloud}/${v}/${skips.length ? "skips" : "noskips"}`] =
          createHash("sha256").update(buildSql(engine, text, params, values, skips)).digest("hex");
    }
  }
  for (const cloud of ["aws", "gcp", "databricks"]) for (const k of ["sessionSpans", "events"])
    out[`${cloud}/${k}`] = createHash("sha256").update(ENGINES[cloud][k]).digest("hex");
  return out;
}
if (process.argv.includes("--update")) {
  writeFileSync(SHA_FILE, JSON.stringify(fingerprints(), null, 1) + "\n");
  console.log(`wrote ${SHA_FILE}`);
  process.exit(0);
}
test("AWS, GCP and Databricks SQL (queries, session spans, events table) matches the recorded fingerprints", () => {
  const want = JSON.parse(readFileSync(SHA_FILE, "utf8"));
  const got = fingerprints();
  assert.deepEqual(Object.keys(got).sort(), Object.keys(want).sort(), "the set of queries changed");
  for (const k of Object.keys(want)) assert.equal(got[k], want[k], `${k} changed`);
});

// ---------- Snowflake string literals ----------
const VALUES = ["it's", "a\\b", "\\'", "''", "trailing\\", "->>", "a->>b", "x>y", "line\u2028sep", "vt\u000bab",
  "nel\u0085x", "fs\u001cx", "cr\rx", "crlf\r\nx", "nul\u0000x", "emoji 😀", "s".repeat(200), ""];
test("a quoted Snowflake value passes the script's read-only scan", () => {
  for (const v of VALUES) {
    const err = scan(`SELECT ${sf.quote(v)} AS "v"`);
    assert.ok(passedScan(err), `${JSON.stringify(v)}: ${err.trim()}`);
  }
});
test("negative control: without the > escape, a value holding ->> is refused", () => {
  const naive = v => "'" + v.replace(/[\\']/g, "\\$&") + "'";
  assert.match(scan(`SELECT ${naive("a->>b")} AS "v"`), /refusing to run/);
});
test("a Snowflake literal has no raw >, CR, NUL or character the script refuses", () => {
  for (const v of VALUES) assert.doesNotMatch(sf.quote(v), /[>\x00\x0b-\x0d\x1c-\x1e\x85\u2028\u2029]/, JSON.stringify(v));
});

// ---------- timestamp literals ----------
test("each engine writes its timestamp literal", () => {
  const q = "'2026-11-01 00:00:00.123'";
  assert.equal(ENGINES.aws.ts(q), `TIMESTAMP ${q}`);
  assert.equal(ENGINES.gcp.ts(q), `TIMESTAMP ${q}`);
  assert.equal(ENGINES.databricks.ts(q), `TIMESTAMP_NTZ ${q}`);
  assert.equal(sf.ts(q), `TO_TIMESTAMP_NTZ(${q}, 'YYYY-MM-DD HH24:MI:SS.FF9')`);
});

// ---------- merged-lake rewrite ----------
const sfParams = { since: { pattern: /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\.\d{1,9})?$/, timestamp: true } };
const KEPT_SF = 'FROM (SELECT * FROM "agent_events" WHERE "session_id" IS NULL OR NOT ((';
test("the Snowflake rewrite swaps the quoted events table, qualified or not", () => {
  for (const from of ['"agent_events" ev', '"traceforce"."agent_events" ev', '"traceforce_lakehouse"."traceforce"."agent_events" ev']) {
    const sql = buildSql(sf, `SELECT COUNT(*) AS "n" FROM ${from} WHERE ev."ts" >= {{since}}`, sfParams,
      { since: "2026-11-01 00:00:00" }, SKIPS);
    assert.ok(sql.includes(KEPT_SF), sql);
    assert.ok(sql.includes(') ev WHERE ev."ts" >= TO_TIMESTAMP_NTZ('), sql);
    assert.ok(!sql.includes('"(SELECT'), sql);
    assert.ok(sql.includes(`"session_id" = 'it\\'s\\\\odd' AND "ts" BETWEEN TO_TIMESTAMP_NTZ(`), sql);
    assert.ok(passedScan(scan(sql)), sql);
  }
});
test("mutation: the other engines' pattern would break a Snowflake query", () => {
  const broken = buildSql({ ...sf, eventsPattern: ENGINES.aws.eventsPattern }, 'SELECT 1 AS "n" FROM "agent_events" ev', {}, {}, SKIPS);
  assert.ok(broken.includes('"(SELECT'), broken);
});
test("a skip-list id with $& or $' is inlined as text, not as a replacement pattern", () => {
  for (const engine of [ENGINES.aws, sf]) {
    const sql = buildSql(engine, `SELECT 1 FROM ${engine.events}`, {}, {}, [{ session_id: "a$&b$'c", t0: "2026-11-01 00:00:00", t1: "2026-11-01 00:00:01" }]);
    assert.ok(sql.includes("a$&b$"), sql);
    assert.ok(!sql.includes(`a${engine.events}b`), sql);
  }
});

// ---------- CSV header case ----------
test("Snowflake headers are lowercased, with a warning; numbers parse", () => {
  const warnings = [];
  const rows = parseCsv("SESSIONS,COST_USD,model\n3,1e-05,x\n", { lowerHeader: true, label: "t.sql", warn: m => warnings.push(m) });
  assert.deepEqual(rows, [{ sessions: 3, cost_usd: 0.00001, model: "x" }]);
  assert.deepEqual(warnings, ["warning: t.sql returned uppercase column SESSIONS", "warning: t.sql returned uppercase column COST_USD"]);
});
test("two columns that lowercase to one name are reported", () => {
  const warnings = [];
  parseCsv("A,a\n1,2\n", { lowerHeader: true, label: "t.sql", warn: m => warnings.push(m) });
  assert.ok(warnings.includes("warning: t.sql returned column a twice"), warnings.join("; "));
});
test("other engines keep the header as it is", () => {
  const warnings = [];
  assert.deepEqual(parseCsv("SESSIONS\n3\n", { warn: m => warnings.push(m) }), [{ SESSIONS: "3" }]);
  assert.equal(warnings.length, 0);
});

// ---------- script messages ----------
test("Python warnings are dropped from a script's messages; its own lines are kept", () => {
  const stderr = "/x/lib/connection/_connection.py:137: FutureWarning: enable_server_session_keep_alive_auto_detection was not set\n" +
    "  options = self.config.to_proto_options(\n-- 0 rows\n<sys>:0: FutureWarning: Connection was not explicitly closed\n" +
    "000606 (57P03): No active warehouse selected in the current session.\n";
  assert.deepEqual(scriptMessages(stderr), ["-- 0 rows", "000606 (57P03): No active warehouse selected in the current session."]);
});

// ---------- literals and placeholders ----------
const P = { person: { pattern: /^[a-z.]+@[a-z.]+$/, emptyIsNull: true }, since: { pattern: /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/, timestamp: true } };
test("literal(): NULL for an allowed empty value; an error for a bad or unknown parameter", () => {
  assert.equal(literal(sf, P, "person", ""), "NULL");
  assert.equal(literal(sf, P, "person", "a@b.c"), "'a@b.c'");
  assert.equal(literal(ENGINES.aws, P, "since", "2026-11-01 00:00:00"), "TIMESTAMP '2026-11-01 00:00:00'");
  assert.throws(() => literal(sf, P, "person", "x' OR 1=1 --"), BadRequest);
  assert.throws(() => literal(sf, P, "since", ""), BadRequest);
  assert.throws(() => literal(sf, P, "nope", "x"), BadRequest);
});
test("buildSql(): every placeholder is filled, or it's an error", () => {
  assert.equal(buildSql(sf, "WHERE p = {{person}} OR q = {{person}}", P, { person: "a@b.c" }), "WHERE p = 'a@b.c' OR q = 'a@b.c'");
  assert.throws(() => buildSql(sf, "WHERE p = {{person}} AND t >= {{since}}", P, { person: "a@b.c" }), BadRequest);
});
test("every {{placeholder}} in every query file is a parameter its dashboard declares", () => {
  for (const { name, dir, params } of dashboards) for (const engine of Object.values(ENGINES)) for (const f of sqlFiles(dir, engine)) {
    const text = readFileSync(join(dir, engine.queries, f), "utf8");
    for (const [, p] of text.matchAll(/\{\{(\w+)\}\}/g)) assert.ok(Object.hasOwn(params, p), `${name}/${engine.queries}/${f}: {{${p}}} isn't in params`);
  }
});

// ---------- CSV parsing ----------
test("parseCsv(): quoted commas, newlines and doubled quotes; CRLF; no header for an empty result", () => {
  assert.deepEqual(parseCsv('model,sessions\r\n"a, ""b""\nc",2\r\n'), [{ model: 'a, "b"\nc', sessions: 2 }]);
  assert.deepEqual(parseCsv("model,cost_usd\nx,\n"), [{ model: "x", cost_usd: null }]);
  assert.deepEqual(parseCsv(""), []);
});

// ---------- Snowflake error messages ----------
// Recorded from snowflake_query.sh on the test account (request ids shortened).
const SF_ERRORS = {
  noCredentials: "000007: Configuration error: Connection 'default' not found in config files",
  badKey: "390144 (28000): Failed to login: Login error: JWT token is invalid.  [54e2cbcf], code: 390144",
  wrongAccount: "250001 (08001): Failed to login: Invalid Snowflake response. Snowflake responded with error status: 404 Not Found, message: Unexpected response, body length 14838.",
  noRole: "100132 (P0000): JavaScript execution error: Uncaught Execution of multiple statements failed on statement \"USE ROLE \"traceforce_lakehouse...\" (at line 1, position 0).\nSQL access control error:\nRequested role '\"traceforce_lakehouse_reader\"' is not assigned to the executing user.  Specify another role to activate. in SYSTEM$MULTISTMT at '    throw `Execution of multiple statements failed on statement {0} (at line {1}, position {2}).`.replace('{1}', LINES[i])' position 4\nstackstrace: \nSYSTEM$MULTISTMT line: 10 (request_id=b935ce89, sfqid=01c87031)",
  noWarehouse: "000606 (57P03): No active warehouse selected in the current session.  Select an active warehouse with the 'use warehouse' command.\n (request_id=b63a11a6, sfqid=01c87032)",
  invalidIdentifier: "100132 (P0000): JavaScript execution error: Uncaught Execution of multiple statements failed on statement \"SELECT \"nope\" FROM \"agent_even...\" (at line 1, position 256).\nSQL compilation error: error line 1 at position 7\ninvalid identifier '\"nope\"' in SYSTEM$MULTISTMT at '    throw `Execution of ...`...' position 4\nstackstrace: \nSYSTEM$MULTISTMT line: 10 (request_id=x, sfqid=y)",
  useWarehouse: "100132 (P0000): JavaScript execution error: Uncaught Execution of multiple statements failed on statement \"USE WAREHOUSE \"no_such_wh\"\" (at line 1, position 0).\nSQL compilation error:\nObject does not exist, or operation cannot be performed. in SYSTEM$MULTISTMT at '    throw `Execution of multiple statements failed on statement {0} (at line {1}, position {2}).`.replace('{1}', LINES[i])' position 4\nstackstrace: \nSYSTEM$MULTISTMT line: 10 (request_id=4865d194, sfqid=01c87045)",
  namedConnection: "000007: Configuration error: Connection 'nope_review' not found in config files",
  // Recorded with a wrong password; the second form, reported in review, also says "Failed to connect".
  badPassword: "390100 (28000): Failed to login: Login error: Incorrect username or password was specified. [17896430-d993-4d44-9e3b-600806475398], code: 390100",
  badPasswordConnect: "250001 (08001): Failed to connect to DB: acme-xy12345.snowflakecomputing.com:443. Incorrect username or password was specified.",
  noTable: "100132 (P0000): JavaScript execution error: Uncaught Execution of multiple statements failed on statement \"SELECT * FROM \"no_such_table\"\" (at line 1, position 256).\nSQL compilation error:\nObject '\"no_such_table\"' does not exist or not authorized. Your primary role traceforce_lakehouse_reader must have at least one privilege granted on TABLE \"no_such_table\". in SYSTEM$MULTISTMT at '    throw `Execution of multiple statements failed on statement {0} (at line {1}, position {2}).`.replace('{1}', LINES[i])' position 4\nstackstrace: \nSYSTEM$MULTISTMT line: 10 (request_id=9e0cac50, sfqid=01c8703a)",
};
test("snowflakeError(): the cause inside the multi-statement wrapper, else the first line", () => {
  assert.equal(snowflakeError(SF_ERRORS.noTable.split("\n")),
    "SQL compilation error: Object '\"no_such_table\"' does not exist or not authorized. Your primary role traceforce_lakehouse_reader must have at least one privilege granted on TABLE \"no_such_table\".");
  assert.match(snowflakeError(SF_ERRORS.noRole.split("\n")), /^SQL access control error: Requested role .* is not assigned to the executing user\.  Specify another role to activate\.$/);
  assert.equal(snowflakeError(SF_ERRORS.invalidIdentifier.split("\n")), "SQL compilation error: error line 1 at position 7 invalid identifier '\"nope\"'");
  assert.equal(snowflakeError(SF_ERRORS.noWarehouse.split("\n")), SF_ERRORS.noWarehouse.split("\n")[0]);
  assert.equal(snowflakeError(["one line"]), "one line");
});
test("classifySnowflakeError(): each recorded failure gets its own diagnosis", () => {
  const via = "the SNOWFLAKE_* variables";
  const want = {
    noCredentials: "No Snowflake credentials found",
    badKey: `Snowflake refused the sign-in from ${via}`,
    wrongAccount: "Couldn't reach the Snowflake account",
    noRole: "You don't have the lakehouse's reader role",
    noWarehouse: "No usable query warehouse for the reader role",
    noTable: 'No "traceforce_lakehouse" lakehouse visible in this Snowflake account',
    invalidIdentifier: "Snowflake refused the query",
    useWarehouse: 'The lakehouse\'s query warehouse "traceforce_lakehouse_query" can\'t run the query',
    namedConnection: 'connections.toml has no connection named "nope_review"',
    badPassword: `Snowflake refused the sign-in from ${via}`,
    badPasswordConnect: `Snowflake refused the sign-in from ${via}`,
  };
  for (const [k, text] of Object.entries(SF_ERRORS)) assert.equal(classifySnowflakeError(text, via).what, want[k], k);
  assert.match(classifySnowflakeError(SF_ERRORS.wrongAccount, via).fix, /404 Not Found/);
  assert.deepEqual(classifySnowflakeError("something new", via), { what: "Snowflake refused the query", fix: "something new" });
  // The script's own credential messages name SNOWFLAKE_AUTHENTICATOR; they aren't a refused sign-in.
  assert.notEqual(classifySnowflakeError("SNOWFLAKE_AUTHENTICATOR must be SNOWFLAKE_JWT for key-pair auth (got: x)", via).what, `Snowflake refused the sign-in from ${via}`);
});

// ---------- static rules for queries/snowflake/*.sql ----------
// The SQL with comments and string contents blanked out (same length, newlines kept), so keywords, quotes
// and commas inside them don't count. Snowflake strings take backslash escapes.
function code(sql) {
  const out = [...sql];
  const blank = (a, b) => { for (let k = a; k < b; k++) if (out[k] !== "\n") out[k] = " "; };
  for (let i = 0; i < sql.length;) {
    if (sql.startsWith("--", i)) { const e = sql.indexOf("\n", i); blank(i, e < 0 ? sql.length : e); i = e < 0 ? sql.length : e; }
    else if (sql.startsWith("/*", i)) { const e = sql.indexOf("*/", i + 2), end = e < 0 ? sql.length : e + 2; blank(i, end); i = end; }
    else if (sql[i] === "'") { let j = i + 1; while (j < sql.length && sql[j] !== "'") j += sql[j] === "\\" ? 2 : 1; blank(i + 1, j); i = j + 1; }
    else if (sql[i] === '"') { const e = sql.indexOf('"', i + 1); i = e < 0 ? sql.length : e + 1; }
    else i++;
  }
  return out.join("");
}
// Parenthesis depth after each character (comments and strings already blanked; quoted names skipped).
function depths(text) {
  const d = new Array(text.length);
  let depth = 0, inName = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '"') inName = !inName;
    else if (!inName && c === "(") depth++;
    else if (!inName && c === ")") depth--;
    d[i] = depth;
  }
  return d;
}
// Every SELECT list: [start, end) spans in the text, up to its FROM (not IS [NOT] DISTINCT FROM) or the end
// of its parenthesis level.
function selectLists(text, d) {
  const lists = [];
  for (const m of text.matchAll(/\bSELECT\b(\s+DISTINCT\b)?/gi)) {
    const level = d[m.index], start = m.index + m[0].length;
    let end = start;
    while (end < text.length && d[end] >= level &&
      !(d[end] === level && /^FROM\b/i.test(text.slice(end)) && /\W/.test(text[end - 1]) &&
        !/\bIS\s+(?:NOT\s+)?DISTINCT\s+$/i.test(text.slice(start, end)))) end++;
    lists.push({ at: m.index, level, start, end });
  }
  return lists;
}
// The items of a list: [start, end) spans split at commas outside parentheses and quoted names.
function itemSpans(text, d, start, end, level) {
  const spans = [];
  let from = start, inName = false;
  for (let i = start; i < end; i++) {
    if (text[i] === '"') inName = !inName;
    else if (!inName && text[i] === "," && d[i] === level) { spans.push([from, i]); from = i + 1; }
  }
  spans.push([from, end]);
  return spans.filter(([a, b]) => text.slice(a, b).trim());
}
// Every output column has a double-quoted lowercase alias, or is a quoted lowercase column: an unquoted
// alias (or none) comes back uppercase or named after the expression.
export function aliasProblems(sql) {
  const text = code(sql), d = depths(text), out = [];
  for (const { start, end, level } of selectLists(text, d)) for (const [a, b] of itemSpans(text, d, start, end, level)) {
    const item = text.slice(a, b).trim(), shown = sql.slice(a, b).trim();
    if (/^(?:\w+\.)?\*$/.test(item)) continue;
    const m = item.match(/\bAS\s+("[^"]*"|[A-Za-z_]\w*)$/i) || item.match(/^(?:\w+\.)?("[^"]*")$/);
    if (!m) out.push(`unquoted or missing alias: ${shown}`);
    else if (!m[1].startsWith('"')) out.push(`unquoted alias ${m[1]}`);
    else if (m[1] !== m[1].toLowerCase()) out.push(`alias ${m[1]} isn't lowercase`);
  }
  return out;
}
// A GROUP BY by an unqualified quoted name that is also the alias of a derived value in the same SELECT:
// Snowflake groups by the source column of that name, not the alias. Group by position or a CTE's column.
export function groupByProblems(sql) {
  const text = code(sql), d = depths(text), lists = selectLists(text, d), out = [];
  for (const g of text.matchAll(/\bGROUP\s+BY\b/gi)) {
    const level = d[g.index];
    let end = g.index + g[0].length;
    while (end < text.length && d[end] >= level && !(d[end] === level && /\W/.test(text[end - 1]) &&
      /^(?:HAVING|ORDER|QUALIFY|LIMIT|WINDOW|UNION|EXCEPT|INTERSECT|MINUS)\b|^;/i.test(text.slice(end)))) end++;
    const list = lists.filter(l => l.at < g.index && l.level === level).at(-1);
    if (!list) continue;
    for (const [, name] of text.slice(g.index, end).matchAll(/(?<![\w."])"([^"]+)"/g)) {
      for (const [a, b] of itemSpans(text, d, list.start, list.end, level)) {
        const m = text.slice(a, b).trim().match(new RegExp(`^([\\s\\S]+?)\\s+AS\\s+"${name}"$`, "i"));
        if (m && !new RegExp(`^(?:\\w+\\.)?"${name}"$`).test(m[1].trim()))
          out.push(`GROUP BY "${name}" names the derived alias of ${sql.slice(a, b).trim().replace(new RegExp(`\\s+AS\\s+"${name}"$`, "i"), "")}`);
      }
    }
  }
  return out;
}
test("the alias rule flags the bad fixture and passes the good one", () => {
  assert.deepEqual(aliasProblems(readFileSync(join(FIXTURES, "snowflake_good.sql"), "utf8")), []);
  assert.deepEqual(aliasProblems(readFileSync(join(FIXTURES, "snowflake_bad_alias.sql"), "utf8")),
    ["unquoted alias sessions", 'alias "Cost_USD" isn\'t lowercase']);
});
test("the GROUP BY rule flags the bad fixture and passes the good one", () => {
  assert.deepEqual(groupByProblems(readFileSync(join(FIXTURES, "snowflake_good.sql"), "utf8")), []);
  assert.deepEqual(groupByProblems(readFileSync(join(FIXTURES, "snowflake_bad_groupby.sql"), "utf8")),
    ['GROUP BY "agent" names the derived alias of LOWER(REPLACE("agent", \'AGENT_IDENTITY_\', \'\'))']);
});
test("the rules on harder SQL: lowercase keywords, strings, comments, aliases, set operations", () => {
  const cases = [
    ['select lower("agent") as "agent", count(*) as "n" from "agent_events" group by "agent"', [], ['GROUP BY "agent" names the derived alias of lower("agent")']],
    ['SELECT "operation" IS DISTINCT FROM \'x\' AS "f", LOWER("agent") AS "agent" FROM "agent_events" GROUP BY "agent", 1', [], ['GROUP BY "agent" names the derived alias of LOWER("agent")']],
    ['SELECT COUNT(*) sessions, MAX("ts") FROM "agent_events"', ["unquoted or missing alias: COUNT(*) sessions", 'unquoted or missing alias: MAX("ts")'], []],
    ['SELECT \'--\' AS "a", COUNT(*) AS Sessions FROM "agent_events"', ["unquoted alias Sessions"], []],
    ['SELECT /* AS foo, */ COUNT(*) AS "n" FROM "agent_events" AS ev', [], []],
    ['SELECT LOWER(e."agent") AS "agent" FROM "agent_events" e GROUP BY e."agent"', [], []],
    ['SELECT "agent" AS "agent" FROM "agent_events" GROUP BY 1 UNION ALL SELECT LOWER("agent") AS "agent" FROM "agent_events"', [], []],
    ['SELECT \'it\\\'s, "x"\' AS "q", COUNT(*) OVER (PARTITION BY "agent") AS "n" FROM "agent_events"', [], []],
  ];
  for (const [sql, alias, groupBy] of cases) {
    assert.deepEqual(aliasProblems(sql), alias, sql);
    assert.deepEqual(groupByProblems(sql), groupBy, sql);
  }
});
const sfQueries = dashboards.flatMap(d => sqlFiles(d.dir, sf).map(f => ({ label: `${d.name}/${f}`, sql: readFileSync(join(d.dir, sf.queries, f), "utf8") })));
test("every Snowflake query follows the alias and GROUP BY rules and names tables quoted", () => {
  assert.ok(sfQueries.length > 0, "no Snowflake queries found");
  for (const { label, sql } of sfQueries) {
    assert.deepEqual(aliasProblems(sql), [], label);
    assert.deepEqual(groupByProblems(sql), [], label);
    assert.doesNotMatch(code(sql), /(?<!")\bagent_events\b|\btraceforce_lakehouse\./, `${label}: unquoted table name`);
  }
});
// The output column names of a query's last top-level SELECT: an item's alias, else its column name
// (quotes and a table prefix dropped), lowercased as Athena reports them.
function outputColumns(sql) {
  const text = code(sql), d = depths(text);
  const list = selectLists(text, d).filter(l => l.level === 0).at(-1);
  return itemSpans(text, d, list.start, list.end, 0).map(([a, b]) => {
    const item = text.slice(a, b).trim();
    const m = item.match(/\bAS\s+("[^"]*"|[A-Za-z_]\w*)$/i) || item.match(/^(?:\w+\.)?("[^"]*"|[A-Za-z_]\w*)$/);
    return m ? m[1].replace(/"/g, "").toLowerCase() : `?${item}`;
  });
}
const placeholders = sql => [...new Set([...sql.matchAll(/\{\{(\w+)\}\}/g)].map(m => m[1]))].sort();
test("every Snowflake query returns the Athena original's columns, in order, and takes its parameters", () => {
  for (const d of dashboards) for (const f of sqlFiles(d.dir, sf)) {
    const athena = readFileSync(join(d.dir, ENGINES.aws.queries, f), "utf8");
    const snowflake = readFileSync(join(d.dir, sf.queries, f), "utf8");
    assert.deepEqual(outputColumns(snowflake), outputColumns(athena), `${d.name}/${f}: columns`);
    assert.deepEqual(placeholders(snowflake), placeholders(athena), `${d.name}/${f}: parameters`);
  }
});
test("negative control: a dropped column or filter is caught", () => {
  const athena = 'SELECT agent, count(*) AS n FROM agent_events WHERE person = {{person}} GROUP BY 1';
  assert.notDeepEqual(outputColumns('SELECT "agent" AS "agent" FROM "agent_events" GROUP BY 1'), outputColumns(athena));
  assert.notDeepEqual(placeholders('SELECT "agent" AS "agent", COUNT(*) AS "n" FROM "agent_events" GROUP BY 1'), placeholders(athena));
  assert.deepEqual(outputColumns('SELECT "agent", COUNT(*) AS "n" FROM "agent_events" WHERE "person" = {{person}} GROUP BY 1'), outputColumns(athena));
});
test("every Snowflake query passes the script's read-only scan", () => {
  for (const { label, sql } of sfQueries) assert.ok(passedScan(scan(sql)), label);
});
