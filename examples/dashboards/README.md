# TraceForce lakehouse dashboards

Pages that query your TraceForce lakehouse live, served by one small local server. Nothing is cached
on disk.

| dashboard | what it answers |
|---|---|
| [`usage-and-spend/`](usage-and-spend/README.md) | Who uses which AI agents, how much, and what it costs, down to each session's prompts |
| [`incident-triage/`](incident-triage/README.md) | Which sessions leaked sensitive data, ran risky actions or met prompt injections, ranked by severity |

## Run it (AWS / Athena)

In Claude Code with the `traceforce-lakehouse` plugin installed, type `/dashboards` (or ask Claude to
open the dashboards). It checks your AWS access, starts the server in the background and opens your
browser, or tells you exactly what to fix. The server stops when the Claude Code session ends.

From a terminal:

```bash
node serve.mjs --open     # check AWS access, start the server, open http://localhost:8765
```

| flag | does |
|---|---|
| `--open` | open the home page in your browser once the server is up |
| `--check` | only check AWS access, then exit (0 = ready, 2 = something to fix) |
| `--no-check` | skip the AWS check |
| `--port N` | serve on another port (default 8765) |

Before serving, `serve.mjs` checks, in order: the AWS CLI is installed, `AWS_PROFILE` (if set) exists,
a region is set, you're signed in, and your identity can use the `traceforce-lakehouse` Athena
workgroup. The first check that fails stops it with what's wrong and the fix, for example:

```
✗ You're not signed in to AWS, or your session has expired
  Sign in: aws sso login --profile lakehouse
```

If the port already has a dashboards server, it reuses that one (opening it with `--open`) instead of
failing. Stop the server with Ctrl-C.

`serve.mjs` needs Node 18 or later and nothing else. It runs each dashboard's queries through the
skill's `athena_query.sh`, so it needs the same AWS credentials and region (the module's read-only
`query_policy_json` is enough), for example `AWS_PROFILE=... AWS_REGION=... node serve.mjs --open`.
If a page later says it couldn't load from the lake, the terminal running the server shows Athena's
error.

Each page fetches what it shows when it needs it, and keeps it in memory until you reload. A reload
queries the lake again. Athena itself keeps each query's result in the workgroup's S3 result location,
as it does for every query. Opened as a file (`open usage-and-spend/index.html`), a page has no server
and shows generated sample data, labeled as such.

## Security

- The server listens on `127.0.0.1` only, and refuses requests whose `Host` isn't `localhost` or
  `127.0.0.1` (so a web page can't reach it through a DNS name pointed at your machine).
- It serves only each dashboard's `index.html`, the two files in `shared/` and the endpoints each
  dashboard's `api.mjs` declares. It runs only the SQL files in each dashboard's `queries/`.
- Pages send values (a person, a session id, a time), never SQL. Each value must match the pattern
  its dashboard declares before it's inlined as a SQL literal.
- The pages show prompt, command and finding text as stored in the lake (redacted per your policy).
  It's always displayed as plain text, never interpreted as HTML.

## Layout

```
serve.mjs                  the server: home page, shared files, each dashboard's page and endpoints
shared/dashboard.css       look: color tokens (light and dark), layout, charts, tables
shared/dashboard.js        formatting, tooltip, charts, tables, fetching (window.Dash)
<dashboard>/index.html     the page
<dashboard>/api.mjs        its endpoints, and the values its pages may send
<dashboard>/queries/*.sql  its queries; {{name}} placeholders are filled in by serve.mjs
```

## Add a dashboard

Make a folder with an `index.html`, a `queries/` folder and an `api.mjs`. The server picks up every
folder that has an `api.mjs`, serves it at `/<folder>/` and lists it on the home page.

```js
// my-dashboard/api.mjs
export const title = "My dashboard";
export const description = "One line for the home page.";
// The values its pages may send. emptyIsNull: '' becomes NULL. timestamp: inlined as TIMESTAMP '...'.
export const params = {
  person: { pattern: /^[A-Za-z0-9._%+-]{1,128}@[A-Za-z0-9.-]{1,190}$/, emptyIsNull: true },
};
// Served at /my-dashboard/api/<name>. run("x", values) runs queries/x.sql and resolves to its rows.
export const routes = {
  async overview(_, { run }) { return { rows: await run("overview") }; },
  async person(q, { run, arg }) { return { rows: await run("person", { person: arg(q, "person") }) }; },
};
```

In the page, load `../shared/dashboard.css` and `../shared/dashboard.js`, and fetch with
`Dash.api("api/overview")`. Restart the server to pick up a new folder.

## Other clouds

The queries are Athena (Trino) SQL. For BigQuery or Snowflake, translate them as described in the
skill's `SKILL.md`, and point `QUERY` in `serve.mjs` at `bq_query.sh` or `snowflake_query.sh`; they
take the same arguments and print the same CSV.
