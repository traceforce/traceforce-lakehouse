---
name: dashboards
description: "Open the TraceForce lakehouse dashboards (AI agent usage & spend, incident triage) in the browser: checks access to the lakehouse first and says exactly what to fix, then starts the local dashboards server and opens it. Use when someone asks to open, start, launch or show the TraceForce dashboards. AWS (Athena) and GCP (BigQuery) lakehouses."
argument-hint: "[--cloud aws|gcp|gcp,aws] [--port N]"
allowed-tools: Bash(node ${CLAUDE_PLUGIN_ROOT}/examples/dashboards/serve.mjs *)
---

# Open the TraceForce dashboards

The server is `${CLAUDE_PLUGIN_ROOT}/examples/dashboards/serve.mjs` (Node 18+, no packages). It queries
the lakehouse live: through Athena with the user's AWS credentials (`--cloud aws`, the default), or
through BigQuery with their gcloud sign-in (`--cloud gcp`), or both merged into one view (`--cloud gcp,aws`,
which checks both sign-ins). Do the three steps in order, and stop at the
first failure.

Pick the cloud from what the user said or passed in `$ARGUMENTS` ("GCP", "BigQuery", "Google" →
`--cloud gcp`; "AWS", "Athena" → `--cloud aws`; both → `--cloud gcp,aws`). Don't infer it from which CLIs or credentials are
present: a machine often has both. If nothing names it, ask whether their lakehouse is on AWS or GCP.
Pass the same `--cloud` to both commands below. Azure (Snowflake) isn't supported by the dashboards
yet; say so if asked.

## 1. Check access

Run in the foreground:

```bash
node ${CLAUDE_PLUGIN_ROOT}/examples/dashboards/serve.mjs --check $ARGUMENTS
```

It prints a `✓` line per check that passed. On a problem it prints one `✗` line with what's wrong and,
indented under it, the fix, and exits 2. Then:

- Show the user the `✗` line and the fix as printed, and stop. Don't start the server.
- Don't try to fix it yourself. Signing in (`aws sso login`, `gcloud auth login`) opens a browser and
  needs the user: suggest they type the command from the fix here with a `!` prefix (for example
  `! aws sso login --profile <name>` or `! gcloud auth login`), then run this command again.
- AWS: if the fix is about AWS_PROFILE or AWS_REGION, say they can set it in their shell before
  starting Claude Code, or tell you which profile and region to use, and then run step 1 again with
  those set, for example `AWS_PROFILE=x AWS_REGION=y node ...`. If they do, use the same
  variables in step 2.
- GCP: if the fix is about the project, they can run `! gcloud config set project <id>`, or tell you
  the project id, and then run step 1 again with `TRACEFORCE_LAKEHOUSE_PROJECT=<id> node ...`. If they
  do, use the same variable in step 2. A permissions fix (dataViewer, connectionUser, jobUser) needs
  an admin of their GCP project; don't try to grant it.

If `node` itself isn't found, tell the user the dashboards need Node 18 or later, and stop.

## 2. Start the server and open the browser

Run in the background (it keeps serving until stopped), with the same arguments and variables as step 1:

```bash
node ${CLAUDE_PLUGIN_ROOT}/examples/dashboards/serve.mjs --no-check --open $ARGUMENTS
```

Then read its output until one of these appears (usually within a couple of seconds):

- `Serving on http://localhost:<port>/`: started; the browser is opening.
- `Dashboards are already running at http://localhost:<port>/`: an earlier server is still up; the
  browser opens it, and this process exits 0. Nothing more to start.
- A `✗` line (exit 2), for example a port used by another program: show it with its fix, and stop.

## 3. Tell the user

In a few lines:

- The URL (`http://localhost:<port>/`), and that the home page links to each dashboard (listed under
  "Serving on" in the output).
- Each page takes a few seconds to load, because it queries the lakehouse live.
- The server runs in the background of this Claude Code session and stops when the session ends; they
  can ask you to stop it sooner. If it was already running, say so instead.

The pages and their queries are described in `${CLAUDE_PLUGIN_ROOT}/examples/dashboards/README.md`.
