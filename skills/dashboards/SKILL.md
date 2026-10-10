---
name: dashboards
description: "Open the TraceForce lakehouse dashboards (AI agent usage & spend, incident triage) in the browser: checks AWS access to the lakehouse first and says exactly what to fix, then starts the local dashboards server and opens it. Use when someone asks to open, start, launch or show the TraceForce dashboards. AWS (Athena) lakehouses only."
argument-hint: "[--port N]"
allowed-tools: Bash(node ${CLAUDE_PLUGIN_ROOT}/examples/dashboards/serve.mjs *)
---

# Open the TraceForce dashboards

The server is `${CLAUDE_PLUGIN_ROOT}/examples/dashboards/serve.mjs` (Node 18+, no packages). It queries
the lakehouse live through Athena with the user's AWS credentials. Do the three steps in order, and stop
at the first failure.

## 1. Check AWS access

Run in the foreground:

```bash
node ${CLAUDE_PLUGIN_ROOT}/examples/dashboards/serve.mjs --check $ARGUMENTS
```

It prints a `✓` line per check that passed. On a problem it prints one `✗` line with what's wrong and,
indented under it, the fix, and exits 2. Then:

- Show the user the `✗` line and the fix as printed, and stop. Don't start the server.
- Don't try to fix it yourself. Signing in (`aws sso login`) opens a browser and needs the user: suggest
  they type `! aws sso login --profile <name>` (the command from the fix) here, then run this command
  again. If the fix is about AWS_PROFILE or AWS_REGION, say they can set it in their shell before
  starting Claude Code, or tell you which profile and region to use, and then run step 1 again with
  those set, for example `AWS_PROFILE=x AWS_REGION=y node ...`. If they do, use the same
  variables in step 2.

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
