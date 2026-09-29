# TraceForce lakehouse — agent guide

This repo is a Terraform module plus a portable skill for querying the TraceForce lakehouse in
plain language: read-only, over Apache Iceberg tables in your own cloud — **Athena** on AWS
(S3), or **BigQuery** on GCP (GCS). Your lakehouse is set up on one of them; use that cloud's
script (`athena_query.sh` for AWS, `bq_query.sh` for GCP; in PowerShell (Windows), the `.ps1`
twins).

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

On Windows (PowerShell):

```
git clone https://github.com/traceforce/traceforce-lakehouse.git $HOME\traceforce-lakehouse
New-Item -ItemType Directory -Force $HOME\.agents\skills | Out-Null
Copy-Item -Recurse $HOME\traceforce-lakehouse\skills\traceforce-lakehouse $HOME\.agents\skills\
```

To update:

```
git -C ~/traceforce-lakehouse pull && rm -rf ~/.agents/skills/traceforce-lakehouse && cp -R ~/traceforce-lakehouse/skills/traceforce-lakehouse ~/.agents/skills/
```

On Windows (PowerShell):

```
git -C $HOME\traceforce-lakehouse pull
Remove-Item -Recurse -Force $HOME\.agents\skills\traceforce-lakehouse
Copy-Item -Recurse $HOME\traceforce-lakehouse\skills\traceforce-lakehouse $HOME\.agents\skills\
```

Only Claude Code is verified end to end so far.

## Prerequisites

- **AWS (Athena):** AWS CLI v2 with credentials in your shell that carry the module's read-only
  `query_policy_json` (or broader), and the lake's region set.
- **GCP (BigQuery):** the gcloud CLI signed in (`gcloud auth login` + `gcloud auth
  application-default login`) with the lakehouse's project as your default
  (`gcloud config set project <id>`).
- Read-only: the query scripts refuse non-read statements (see each script's allowlist), and
  the query identity grants no writes.
