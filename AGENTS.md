# TraceForce lakehouse — agent guide

This repo is a Terraform module plus a portable skill for querying the TraceForce lakehouse in
plain language: read-only, over Apache Iceberg tables in your own cloud — **Athena** or
**Snowflake** on AWS (S3), **BigQuery** on GCP (GCS), or **Snowflake** or **Databricks** on Azure
(Blob Storage / ADLS Gen2). Your lakehouse is set up on one of them; use its script
(`athena_query.sh` for AWS Athena, `bq_query.sh` for GCP, `snowflake_query.sh` for Snowflake on AWS
or Azure, `databricks_query.sh` for Azure Databricks).

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

## Agents inside the data platform (Databricks Genie, Snowflake Cortex, ...)

Add the `skills/traceforce-lakehouse` folder in the agent's skill settings, e.g. Genie One:
Customizations > Skills > + New > Upload Skills (or a workspace admin copies it to
`/Workspace/.assistant/skills/` so everyone in the workspace gets it); Cortex Code: Agent Settings >
Skills. These agents query as each user, so readers need the module's grants; the helper scripts
aren't used there.

Only Claude Code is verified end to end so far.

## Prerequisites

- **AWS (Athena):** AWS CLI v2 with credentials in your shell that carry the module's read-only
  `query_policy_json` (or broader), and the lake's region set.
- **GCP (BigQuery):** the gcloud CLI signed in (`gcloud auth login` + `gcloud auth
  application-default login`) with the lakehouse's project as your default
  (`gcloud config set project <id>`).
- **Snowflake (AWS or Azure):** Python 3 (`python3`, `python` or `py -3`) with
  `snowflake-connector-python`, and either all five `SNOWFLAKE_*` environment variables (listed in
  `snowflake_query.sh`) or a `connections.toml` connection, for a user that holds the
  `traceforce_lakehouse_reader` role.
- **Azure (Databricks):** Python 3 (`python3`, `python` or `py -3`), `DATABRICKS_HOST` and
  `TRACEFORCE_LAKEHOUSE_WAREHOUSE_ID` (the module's `databricks_workspace_url` and
  `query_warehouse_id`), and the Azure CLI signed in (`az login`), the Databricks CLI signed in
  (`databricks auth login`) or `DATABRICKS_CLIENT_ID` / `DATABRICKS_CLIENT_SECRET` for a read-only
  service principal, listed in the module's reader inputs (its Databricks OAuth secret, generated
  in Databricks; not an Entra client secret).
- Read-only: `athena_query.sh` / `bq_query.sh` / `snowflake_query.sh` / `databricks_query.sh` refuse non-read statements
  (see each script's allowlist), and the query identity should be a read-only reader (on Azure,
  not the deployer or a workspace admin); on Snowflake the script also runs every query as the
  read-only reader role.
