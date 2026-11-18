// The per-engine SQL logic serve.mjs uses, kept apart from the server so a test can import it without
// starting one or reaching a cloud (tests/dashboards/test_engines.mjs). Not served: serve.mjs only
// serves index.html, the shared files and each dashboard's routes.
import { join } from "node:path";

export const DATASET = "traceforce_lakehouse";

// Columns the pages treat as numbers. Empty cells are SQL NULLs ("not reported"), kept distinct from 0.
export const NUM = new Set(["sessions", "prompts", "tool_calls", "requests", "calls", "tokens", "live_devices",
  "input_tokens", "output_tokens", "cache_read_tokens", "cost_usd", "findings", "open_findings", "blocks"]);

// The line of a failed query's messages to show: the other scripts end with the reason.
const lastLine = lines => lines.at(-1);
// snowflake_query.sh sends its USE statements and the query as one multi-statement request, so Snowflake
// wraps a statement's error as "100132 … Execution of multiple statements failed on statement …", with the
// cause on the following lines, ended by " in SYSTEM$MULTISTMT at …". Show the cause; else the first line,
// which holds the error code (a later one can be just "(request_id=…)").
export function snowflakeError(lines) {
  if (lines.length > 1 && /Execution of multiple statements failed/.test(lines[0])) {
    const cause = [];
    for (const l of lines.slice(1)) {
      const at = l.indexOf(" in SYSTEM$MULTISTMT");
      cause.push((at >= 0 ? l.slice(0, at) : l).trim());
      if (at >= 0) break;
    }
    if (cause.join(" ").trim()) return cause.join(" ").trim();
  }
  return lines[0];
}

// A character as its \uXXXX escape, which GoogleSQL, Databricks SQL and Snowflake string literals all decode.
const u4 = c => "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0");

// The lakehouse's cloud picks the query script, the folder of SQL in its dialect, how a string literal is
// quoted (GoogleSQL, Databricks SQL and Snowflake have backslash escapes, not only doubled quotes: on
// Databricks 'it''s' reads as two literals joined, "its"), how a timestamp literal is written (ts), how a
// column is named in SQL this file writes (col), the events table and how a query names it
// (eventsPattern), and the query listing its recent session ids.
export const ENGINES = {
  aws: { script: "athena_query.sh", queries: "queries", errorLine: lastLine,
    quote: v => "'" + v.replaceAll("'", "''") + "'", ts: q => `TIMESTAMP ${q}`, col: name => name,
    events: "agent_events", eventsPattern: /\b(?:traceforce_lakehouse\.(?:traceforce\.)?)?agent_events\b/g,
    sessionSpans: "SELECT session_id, cast(min(ts) AS varchar) AS t0, cast(max(ts) AS varchar) AS t1 FROM agent_events " +
      "WHERE session_id IS NOT NULL AND ts >= date_add('day', -92, current_date) GROUP BY session_id" },
  gcp: { script: "bq_query.sh", queries: join("queries", "bigquery"), errorLine: lastLine,
    quote: v => "'" + v.replace(/[\\']/g, "\\$&") + "'", ts: q => `TIMESTAMP ${q}`, col: name => name,
    events: `${DATASET}.agent_events`, eventsPattern: /\b(?:traceforce_lakehouse\.(?:traceforce\.)?)?agent_events\b/g,
    sessionSpans: "SELECT session_id, FORMAT_TIMESTAMP('%F %H:%M:%E6S', min(ts)) AS t0, FORMAT_TIMESTAMP('%F %H:%M:%E6S', max(ts)) AS t1 " +
      `FROM ${DATASET}.agent_events WHERE session_id IS NOT NULL AND ts >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 92 DAY)) GROUP BY session_id` },
  databricks: { script: "databricks_query.sh", queries: join("queries", "databricks"), errorLine: lastLine,
    // databricks_query.sh refuses these characters anywhere in a statement; a session id from another lake
    // (the duplicate-session skip list) can hold them, so they're written as \uXXXX escapes.
    quote: v => "'" + v.replace(/[\\']/g, "\\$&").replace(/[\x0b\x0c\x1c-\x1e\x85\u2028\u2029]/g, u4) + "'",
    // A TIMESTAMP literal is read in the session's time zone, and inside a daylight-saving gap it moves an hour.
    ts: q => `TIMESTAMP_NTZ ${q}`, col: name => name,
    events: `${DATASET}.traceforce.agent_events`, eventsPattern: /\b(?:traceforce_lakehouse\.(?:traceforce\.)?)?agent_events\b/g,
    // ts is UTC; the UTC date, not current_date(), which follows the session time zone.
    sessionSpans: "SELECT session_id, CAST(min(ts) AS STRING) AS t0, CAST(max(ts) AS STRING) AS t1 " +
      `FROM ${DATASET}.traceforce.agent_events WHERE session_id IS NOT NULL AND ts >= CAST(date_sub(to_date(` +
      "timestampadd(MICROSECOND, unix_micros(current_timestamp()), TIMESTAMP_NTZ '1970-01-01 00:00:00')), 92) AS TIMESTAMP_NTZ) " +
      "GROUP BY session_id" },
  snowflake: { script: "snowflake_query.sh", queries: join("queries", "snowflake"), errorLine: snowflakeError,
    // snowflake_query.sh refuses "->>" and these characters anywhere in a statement, literals included; a
    // session id from another lake can hold them, so they're written as \uXXXX escapes. Every ">" is, so
    // no value can form "->>". So are CR (the script reads the SQL with universal newlines, which would
    // turn it into LF) and NUL (a process argument can't hold one).
    quote: v => "'" + v.replace(/[\\']/g, "\\$&").replace(/[>\x00\x0b-\x0d\x1c-\x1e\x85\u2028\u2029]/g, u4) + "'",
    // Explicit type and format: a bare TIMESTAMP '…' follows the account's TIMESTAMP_TYPE_MAPPING (may be
    // LTZ), and a bare string cast its TIMESTAMP_INPUT_FORMAT. FF9 reads 0 to 9 fraction digits.
    ts: q => `TO_TIMESTAMP_NTZ(${q}, 'YYYY-MM-DD HH24:MI:SS.FF9')`,
    // Identifiers are case-preserved lowercase; unquoted ones fold to uppercase and don't exist.
    col: name => `"${name}"`,
    events: '"agent_events"', eventsPattern: /(?:(?:"traceforce_lakehouse"\.)?"traceforce"\.)?"agent_events"/g,
    // Unquoted output aliases come back uppercase: lowercase the header, and warn (see parseCsv).
    lowerHeader: true,
    // The script pins the session time zone to UTC, so CURRENT_DATE() is the UTC date.
    sessionSpans: "SELECT \"session_id\" AS \"session_id\", TO_CHAR(MIN(\"ts\"), 'YYYY-MM-DD HH24:MI:SS.FF6') AS \"t0\", " +
      "TO_CHAR(MAX(\"ts\"), 'YYYY-MM-DD HH24:MI:SS.FF6') AS \"t1\" FROM \"agent_events\" WHERE \"session_id\" IS NOT NULL " +
      "AND \"ts\" >= DATEADD('day', -92, CURRENT_DATE())::TIMESTAMP_NTZ GROUP BY \"session_id\"" },
};

// RFC 4180 CSV, as the query scripts write it: quoted fields may hold commas, doubled quotes and newlines.
// With lowerHeader (Snowflake), header names are lowercased and each one that wasn't is reported through
// warn: the pages read lowercase keys, and an unquoted Snowflake alias comes back uppercase.
export function parseCsv(text, { lowerHeader = false, label = "query", warn = console.error } = {}) {
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
  let [head = [], ...body] = rows;
  if (lowerHeader) head = head.map((k, j) => {
    const lower = k.toLowerCase();
    if (k !== lower) warn(`warning: ${label} returned uppercase column ${k}`);
    if (head.findIndex(h => h.toLowerCase() === lower) !== j) warn(`warning: ${label} returned column ${lower} twice`);
    return lower;
  });
  return body.map(r => Object.fromEntries(head.map((k, j) => {
    const v = r[j] ?? "";
    return [k, v === "" ? null : NUM.has(k) ? Number(v) : v];
  })));
}

export class BadRequest extends Error {}

// A checked page value as a SQL literal in one engine's dialect.
export function literal(engine, params, name, value) {
  const spec = params[name];
  if (!spec) throw new BadRequest(`unknown parameter ${name}`);
  if (spec.emptyIsNull && value === "") return "NULL";
  if (!spec.pattern.test(value)) throw new BadRequest(`invalid ${name}`);
  const quoted = engine.quote(value);
  return spec.timestamp ? engine.ts(quoted) : quoted;
}

// One query's SQL for one lake: each {{param}} replaced by its checked literal, and, with a skip list (spans
// earlier-listed lakes hold of its sessions), the events table swapped for a subquery without those events.
export function buildSql(engine, text, params, values = {}, skips = [], name = "query") {
  let sql = text;
  for (const [k, v] of Object.entries(values)) sql = sql.replaceAll(`{{${k}}}`, literal(engine, params, k, v));
  if (sql.includes("{{")) throw new BadRequest(`${name}.sql needs a parameter that wasn't given`);
  if (skips.length) {
    const { quote: q, ts, col } = engine;
    const held = skips.map(x => `(${col("session_id")} = ${q(x.session_id)} AND ${col("ts")} BETWEEN ${ts(q(x.t0))} AND ${ts(q(x.t1))})`);
    const kept = `(SELECT * FROM ${engine.events} WHERE ${col("session_id")} IS NULL OR NOT (${held.join(" OR ")}))`;
    // A function, not a string: the ids come from another lake, and "$&" or "$'" in a replacement string
    // would splice in the matched text.
    sql = sql.replace(engine.eventsPattern, () => kept);
  }
  return sql;
}

// A query script's stderr lines without Python warnings, which the Snowflake connector prints on every
// connection: "<file>.py:<n>: …Warning: …" followed by an indented source line, and "<sys>:0: …Warning: …"
// at exit.
export function scriptMessages(stderr) {
  const lines = stderr.split("\n"), out = [];
  for (let i = 0; i < lines.length; i++) {
    if (/^(?:.*\.py|<sys>):\d+: \w*Warning: /.test(lines[i])) { if (/^\s/.test(lines[i + 1] || "")) i++; continue; }
    if (lines[i].trim()) out.push(lines[i]);
  }
  return out;
}

// What a failed Snowflake access probe means, and the fix, from the script's messages (Python warnings
// already dropped). via names where the credentials came from. 250001 ("Failed to login") alone isn't a
// sign-in failure: it also wraps the 404 a wrong organization or account name gets. A failed USE statement
// says only "Object does not exist, or operation cannot be performed"; the multi-statement wrapper names it.
export function classifySnowflakeError(text, via) {
  const shown = snowflakeError(text.split("\n")) || text;
  // Connector 5: "Connection 'X' not found in config files"; 3 and 4: "Invalid connection_name 'X', known ones are [...]".
  const m = text.match(/Connection '([^']*)' not found|Invalid connection_name '([^']*)'/);
  const named = m && (m[1] ?? m[2]);
  if (m && named !== "default")
    return { what: `connections.toml has no connection named "${named}"`, fix: "Fix SNOWFLAKE_DEFAULT_CONNECTION_NAME, or add that connection to connections.toml (in SNOWFLAKE_HOME, by default ~/.snowflake)." };
  if (m || /default connection/i.test(text))
    return { what: "No Snowflake credentials found", fix: "Set all five SNOWFLAKE_* variables (key-pair sign-in, listed in snowflake_query.sh), or add a connections.toml connection (made the default, or named by SNOWFLAKE_DEFAULT_CONNECTION_NAME)." };
  // Sign-in before reach: a refused sign-in can also say "Failed to connect to DB: <host>:443. ...".
  if (/390144|JWT token is invalid|390100|Incorrect username or password/i.test(text))
    return { what: `Snowflake refused the sign-in from ${via}`, fix: "Check the user name and its key (or the connection's sign-in): the private key must match the public key set on the Snowflake user." };
  // The current snowflake_query.sh chooses the query warehouse itself (or a pre-query-warehouse
  // deployment's), and says this when the reader role can use neither. (Before the role rule: it names the role too.)
  if (/no lakehouse warehouse for the reader role/.test(text))
    return { what: "No usable query warehouse for the reader role", fix: 'Re-apply the lakehouse module (it creates the warehouse and the grant), or ask a Snowflake admin: GRANT USAGE ON WAREHOUSE "traceforce_lakehouse_query" TO ROLE "traceforce_lakehouse_reader".' };
  // The script names the reader role at sign-in, so a user without it is refused there (390186). Connector
  // 4 words that "Failed to connect to DB: <host>:443. Role ... is not granted": before the reach rule.
  if (/390186/.test(text) || /role .*(is not assigned|is not granted|does not exist or not authorized)/i.test(text))
    return { what: "You don't have the lakehouse's reader role", fix: 'Ask a Snowflake admin to grant it: GRANT ROLE "traceforce_lakehouse_reader" TO USER <you> (README, "Grant query access").' };
  if (/250003|404 Not Found|403 Forbidden|Failed to connect|could not connect|nodename nor servname|Name or service not known/i.test(text))
    return { what: "Couldn't reach the Snowflake account", fix: `Check the organization and account names (${via}): ${shown}` };
  // 000606: an older query script, which needs a default warehouse to start its request.
  if (/000606|No active warehouse selected/i.test(text))
    return { what: "No usable query warehouse for the reader role", fix: 'The query script is older than these dashboards: update the traceforce-lakehouse plugin (or your copy of the skill); the current script chooses the warehouse itself. Until then, a Snowflake admin can set one for you: ALTER USER <you> SET DEFAULT_WAREHOUSE = "traceforce_lakehouse_query".' };
  if (/warehouse/i.test(text) && /does not exist|not authorized|suspended|cannot be resumed/i.test(text))
    return { what: 'The lakehouse\'s query warehouse "traceforce_lakehouse_query" can\'t run the query', fix: `${shown}\nAsk your Snowflake admin: the warehouse must exist and the reader role must be able to use it. (The module's resource monitor only notifies; a suspended warehouse means another monitor was set to suspend it.)` };
  if (/failed on statement "USE (DATABASE|SCHEMA)/.test(text) || /(Database|Schema|Object) .*does not exist or not authorized/i.test(text))
    return { what: `No "${DATASET}" lakehouse visible in this Snowflake account`, fix: "Check that the account is the one the lakehouse is deployed in (the organization and account names). If it is, ask your admin to grant you the reader role." };
  return { what: "Snowflake refused the query", fix: shown };
}
