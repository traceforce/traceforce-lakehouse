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
- **Azure (Snowflake):** python3 with the `snowflake-connector-python` package installed
  (`pip install snowflake-connector-python`) and either key-pair auth credentials as environment
  variables -- `SNOWFLAKE_ORGANIZATION_NAME`, `SNOWFLAKE_ACCOUNT_NAME`, `SNOWFLAKE_USER`,
  `SNOWFLAKE_AUTHENTICATOR`, `SNOWFLAKE_PRIVATE_KEY` -- all five, unlike the Terraform module's
  own provider, which only reads `SNOWFLAKE_PRIVATE_KEY` from the environment (the organization
  name, account name, and user are non-secret provider arguments there, not env vars) -- or a
  named connection in `connections.toml`, which the script falls through to only when none of
  those five env vars are set (SSO, password or encrypted-key auth all work this way) -- a
  partial set is always an error, never a silent fall-through to connections.toml's default
  connection, since that could otherwise silently query a different Snowflake account entirely.
  Whichever Snowflake user actually connects must also actually hold the `traceforce_lakehouse_reader`
  role -- the module
  leaves `reader_users` empty by default, so valid credentials alone aren't enough: confirmed
  live, the script's own `USE ROLE` fails with "Requested role ... is not assigned to the
  executing user" until either `reader_users` is set in Terraform or someone runs the
  `GRANT ROLE` command from README.md's "Grant query access" step.
- Read-only: `athena_query.sh` / `bq_query.sh` refuse non-read statements (see each script's
  allowlist), and the query identity grants no writes. `snowflake_query.sh` refuses them too,
  but its real guarantee is Snowflake's own RBAC (it always runs as the module's read-only
  `traceforce_lakehouse_reader` role with secondary roles disabled, regardless of what broader
  role the connecting credentials might otherwise hold) *combined with* the script's own
  statement controls -- confirmed live that RBAC alone isn't enough: a connecting identity that
  also holds a broader role (e.g. `ACCOUNTADMIN`, common for whoever deployed this module) could
  otherwise switch to it and write, all within one Snowflake-parsed statement, via a multi-
  statement escape or the `->>` flow operator (see `snowflake_query.sh`'s own comments). Both are
  rejected before the query ever reaches Snowflake, which is what makes the RBAC restriction
  actually hold.
