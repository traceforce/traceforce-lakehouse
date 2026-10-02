# TraceForce lakehouse — agent guide

This repo is a Terraform module plus a portable skill for querying the TraceForce lakehouse in
plain language: read-only, over Apache Iceberg tables in your own cloud — **Athena** on AWS
(S3), **BigQuery** on GCP (GCS), or **Snowflake** on Azure (Blob Storage). Your lakehouse is set
up on one of them; use that cloud's script (`athena_query.sh` for AWS, `bq_query.sh` for GCP,
`snowflake_query.sh` for Azure).

## Claude Code

Install as a plugin:

```
/plugin marketplace add traceforce/traceforce-lakehouse
/plugin install traceforce-lakehouse@traceforce
```

## Any other agent (Cursor, GitHub Copilot, OpenAI Codex, ...)

These load skills from `~/.agents/skills/`. Copy the skill there, then start a new session:

```
git clone https://github.com/traceforce/traceforce-lakehouse.git ~/traceforce-lakehouse
mkdir -p ~/.agents/skills && cp -R ~/traceforce-lakehouse/skills/traceforce-lakehouse ~/.agents/skills/
```

To update:

```
git -C ~/traceforce-lakehouse pull && rm -rf ~/.agents/skills/traceforce-lakehouse && cp -R ~/traceforce-lakehouse/skills/traceforce-lakehouse ~/.agents/skills/
```

Only Claude Code is verified end to end so far.

## Prerequisites

- **AWS (Athena):** AWS CLI v2 with credentials in your shell that carry the module's read-only
  `query_policy_json` (or broader), and the lake's region set.
- **GCP (BigQuery):** the gcloud CLI signed in (`gcloud auth login` + `gcloud auth
  application-default login`) with the lakehouse's project as your default
  (`gcloud config set project <id>`).
- **Azure (Snowflake):** python3 with `snowflake-connector-python`, and either all five
  `SNOWFLAKE_*` environment variables (listed in `snowflake_query.sh`) or a `connections.toml`
  connection, for a user that holds the `traceforce_lakehouse_reader` role.
- Read-only: `athena_query.sh` / `bq_query.sh` / `snowflake_query.sh` refuse non-read statements
  (see each script's allowlist), and the query identity grants no writes; on Snowflake the script
  also runs every query as the read-only reader role.
