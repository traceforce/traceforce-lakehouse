# TraceForce lakehouse — agent guide

This repo is a Terraform module plus a portable skill for querying the TraceForce lakehouse:
read-only Athena over Apache Iceberg tables in your own AWS account, in plain language.

## Claude Code

Install as a plugin:

```
/plugin marketplace add traceforce/traceforce-lakehouse
/plugin install traceforce-lakehouse@traceforce
```

## Any other agent (Cursor, GitHub Copilot, OpenAI Codex, ...)

Point your agent at `skills/traceforce-lakehouse/`:

- Load `skills/traceforce-lakehouse/SKILL.md` and everything under
  `skills/traceforce-lakehouse/reference/` as context.
- Run queries with the bundled script:

  ```
  skills/traceforce-lakehouse/scripts/athena_query.sh "SELECT ..."
  ```

  (Cursor: add `SKILL.md` under `.cursor/rules`. Copilot: reference it from
  `.github/copilot-instructions.md`. Others: add it to your system prompt.)

Only Claude Code is verified end to end so far; the content is the same for every agent.

## Prerequisites

- AWS CLI v2 with credentials in your shell that carry the module's read-only
  `query_policy_json` (or broader), and the lake's region set.
- Read-only: `athena_query.sh` refuses anything but SELECT-style statements, and the
  query policy grants no writes.
