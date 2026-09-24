# TraceForce lakehouse — agent guide

This repo is a Terraform module plus a portable skill for querying the TraceForce lakehouse in
plain language: read-only, over Apache Iceberg tables in your own cloud — **Athena** on AWS
(S3), or **BigQuery** on GCP (GCS). Your lakehouse is set up on one of them; use that cloud's
script (`athena_query.sh` for AWS, `bq_query.sh` for GCP).

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
- Run queries with the bundled script for your cloud:

  ```
  # AWS (Athena):
  skills/traceforce-lakehouse/scripts/athena_query.sh "SELECT ..."
  # GCP (BigQuery):
  skills/traceforce-lakehouse/scripts/bq_query.sh "SELECT ..."
  ```

  (Cursor: add `SKILL.md` under `.cursor/rules`. Copilot: reference it from
  `.github/copilot-instructions.md`. Others: add it to your system prompt.)

Only Claude Code is verified end to end so far. The skill content is identical for every agent; what differs is how you load it, which script your cloud uses (`athena_query.sh` for AWS, `bq_query.sh` for GCP), and how you invoke it (Claude Code injects `${CLAUDE_SKILL_DIR}`; other agents use the path shown above).

## Prerequisites

- **AWS (Athena):** AWS CLI v2 with credentials in your shell that carry the module's read-only
  `query_policy_json` (or broader), and the lake's region set.
- **GCP (BigQuery):** the gcloud CLI signed in (`gcloud auth login` + `gcloud auth
  application-default login`) with the lakehouse's project as your default
  (`gcloud config set project <id>`).
- Read-only: `athena_query.sh` / `bq_query.sh` refuse non-read statements (see each script's allowlist), and
  the query identity grants no writes.
