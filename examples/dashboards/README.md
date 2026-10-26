# TraceForce lakehouse dashboards

Pages that query your TraceForce lakehouse live, served by one small local server. Nothing is cached
on disk.

| dashboard | what it answers |
|---|---|
| [`usage-and-spend/`](usage-and-spend/README.md) | Who uses which AI agents, how much, and what it costs, down to each session's prompts |
| [`incident-triage/`](incident-triage/README.md) | Which sessions leaked sensitive data, ran risky actions or met prompt injections, ranked by severity |

On GCP, the same two dashboards are also in the TraceForce console (Lakehouse in the sidebar), querying
BigQuery from your browser with your own Google sign-in, with nothing to install. Set them up in
Settings › Lakehouse, step 3.

## Run it (AWS / Athena, GCP / BigQuery)

In Claude Code with the `traceforce-lakehouse` plugin installed, type `/traceforce-lakehouse:dashboards` (or ask Claude to
open the dashboards), adding `--cloud gcp` for a GCP lakehouse. It checks your access, starts the
server in the background and opens your browser, or tells you exactly what to fix. The server stops
when the Claude Code session ends.

From a terminal:

```bash
node serve.mjs --open              # AWS: check access, start the server, open http://localhost:8765
node serve.mjs --cloud gcp --open  # the same for a GCP (BigQuery) lakehouse
node serve.mjs --cloud gcp,aws --open  # both, merged into one view
```

| flag | does |
|---|---|
| `--cloud aws\|gcp\|gcp,aws` | the lakehouse's cloud: Athena on AWS (default) or BigQuery on GCP, or several merged (see below) |
| `--open` | open the home page in your browser once the server is up |
| `--check` | only check access, then exit (0 = ready, 2 = something to fix) |
| `--no-check` | skip the access check |
| `--port N` | serve on another port (default 8765) |

Before serving, `serve.mjs` checks, in order:

- **AWS:** the AWS CLI is installed, `AWS_PROFILE` (if set) exists, a region is set, you're signed in,
  and your identity can use the `traceforce-lakehouse` Athena workgroup.
- **GCP:** the gcloud and bq CLIs are installed, a project is set (`TRACEFORCE_LAKEHOUSE_PROJECT`, else
  the gcloud default project), you're signed in to gcloud, and a dry-run query against the
  `traceforce_lakehouse` dataset succeeds (so your identity can both run query jobs and read the
  tables).

The first check that fails stops it with what's wrong and the fix, for example:

```
✗ You're not signed in to AWS, or your session has expired
  Sign in: aws sso login --profile lakehouse
```

With several clouds (for example after moving the lakehouse from AWS to GCP), every query runs on each
lake and the results are merged. A session in more than one lake is counted once: later-listed lakes skip
its events inside the time span an earlier lake holds for it, so a copied session counts once and a session
that continued in the new lake keeps both parts, shown as one session. Findings are merged by id, keeping the
earlier lake's copy. List the newest, most complete lake first. Daily session counts still count a session
that continued across lakes once in each.

If the port already has a dashboards server for the same cloud, it reuses that one (opening it with
`--open`) instead of failing; one for the other cloud stops it with a pointer to `--port`. Stop the server with Ctrl-C.

`serve.mjs` needs Node 18 or later and nothing else. It runs each dashboard's queries through the
skill's query script, so it needs the same credentials:

- **AWS:** `athena_query.sh`, with AWS credentials and a region (the module's read-only
  `query_policy_json` is enough), for example `AWS_PROFILE=... AWS_REGION=... node serve.mjs --open`.
- **GCP:** `bq_query.sh`, with the gcloud CLI signed in (`gcloud auth login`) as an identity that has
  `roles/bigquery.dataViewer` and `connectionUser` on the lakehouse dataset (the module's
  `query_members`) and `roles/bigquery.jobUser` on the project, for example
  `TRACEFORCE_LAKEHOUSE_PROJECT=... node serve.mjs --cloud gcp --open`. Each query may scan at most
  `TRACEFORCE_LAKEHOUSE_MAX_GB` (default 50) GB.

If a page later says it couldn't load from the lake, the terminal running the server shows Athena's or
BigQuery's error.

Each page fetches what it shows when it needs it, and keeps it in memory until you reload. A reload
queries the lake again. Athena itself keeps each query's result in the workgroup's S3 result location,
and BigQuery in its own temporary result tables, as they do for every query. Opened as a file (`open usage-and-spend/index.html`), a page has no server
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
<dashboard>/queries/*.sql  its queries (Athena); {{name}} placeholders are filled in by serve.mjs
<dashboard>/queries/bigquery/*.sql  the same queries in GoogleSQL, for --cloud gcp
```

## Add a dashboard

Make a folder with an `index.html`, a `queries/` folder (and `queries/bigquery/` for GCP) and an `api.mjs`. The server picks up every
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

`queries/*.sql` is Athena (Trino) SQL and `queries/bigquery/*.sql` the same queries in GoogleSQL,
translated as described in the skill's `SKILL.md`. In the GoogleSQL versions, tables are qualified as
`traceforce_lakehouse.<table>`, and timestamps are formatted as `YYYY-MM-DD HH:MM:SS.ffffff` (as Athena
prints them) because the pages send them back as `{{since}}`/`{{until}}` values. Snowflake (Azure)
isn't supported yet: it would need a third set of queries and an entry in `ENGINES` in `serve.mjs`
for `snowflake_query.sh`, which takes the same arguments and prints the same CSV.
