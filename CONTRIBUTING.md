# Contributing

Turn on the commit hooks once per clone (needs [pre-commit](https://pre-commit.com) and
Terraform):

```sh
pre-commit install
```

Each commit then checks the files it adds or changes (`.pre-commit-config.yaml`):

- gitleaks blocks secrets;
- `terraform fmt` formats `.tf` files;
- the skill reference (`skills/traceforce-lakehouse/reference/`) is regenerated from
  `terraform/schema/columns.json` and must match what you stage (changing an existing table in
  `columns.json` recreates it: see [RELEASING.md](RELEASING.md));
- the Databricks SQL templates (`terraform/azure/databricks/sql/`) must not call
  `convert_timezone()`, which depends on the session time zone;
- the shared Snowflake core's copies of the Azure Snowflake module's SQL templates (`sql/`),
  `compute.tf` and `ingest.tf` must match the originals: change both together;
- the golden test's Trino runner must match the AWS module's partition projection settings, and
  `tests/golden/fixture/` must be what `tests/golden/make_fixture.py` generates;
- leftover merge-conflict markers, files over 500 KB (new or grown) and invalid JSON are
  rejected.

If a hook changed files, stage them and commit again. `git commit --no-verify` skips the hooks.

Tests the hooks don't run:

- the golden SQL tests, `tests/golden/` (see its README);
- the Azure Databricks module's role rule set (who may deploy, and the account ID checks), with
  mocked providers, no cloud access: `cd terraform/azure/databricks && terraform init
  -backend=false && terraform test`. Needs Terraform 1.7 or newer; the module itself needs 1.5.
- the shared Snowflake core's wiring, optional resources, input checks and dashboard sign-in, with
  a mocked provider, no cloud access: `cd terraform/snowflake/core && terraform init
  -backend=false && terraform test`. Needs Terraform 1.7 or newer.
- the AWS Snowflake module's names, IAM trust and policy scopes, the Iceberg bucket's TLS-only
  policy, stage names, its region, bucket and warehouse checks, and the dashboards' token relay,
  with mocked providers, no cloud access: `cd terraform/aws/snowflake && terraform init
  -backend=false && terraform test`. Needs Terraform 1.7 or newer.
- the Azure Snowflake module's dashboards token relay, with mocked providers, no cloud access:
  `cd terraform/azure/snowflake && terraform init -backend=false && terraform test`. Needs
  Terraform 1.7 or newer.
- the dashboards' token relay code shared by the AWS Lambda and the Azure Function
  (`terraform/snowflake/relay/relay.mjs`), offline: `node tests/terraform/test_dashboard_relay.mjs`.
  Needs Node 18 or newer.
- the AWS (Athena) module's results bucket policy, with a mocked provider, no cloud access:
  `cd terraform/aws/athena && terraform init -backend=false && terraform test`. Needs Terraform 1.7
  or newer.
- the Azure Databricks query script's read-only checks, offline, no cloud access:
  `tests/skill/test_databricks_query.sh`.
- the dashboards' per-engine SQL (`examples/dashboards/engines.mjs`: string and timestamp literals,
  the merged-lake rewrite, header case, unchanged SQL for the existing engines) and the Snowflake
  queries' alias and GROUP BY rules, offline: `node tests/dashboards/test_engines.mjs`. Needs Node 18
  or newer, bash and python3 (no Snowflake connector or credentials).
- the dashboards' diagnosis of Snowflake sign-in and warehouse failures, with recorded connector
  messages, offline: `node tests/dashboards/test_snowflake_errors.mjs`. Needs Node 18 or newer.
- the dashboards' Snowflake queries, live, as a user holding the reader role (Node 18 or newer, python3
  with snowflake-connector-python and `snowflake_query.sh`'s credentials):
  - `tests/dashboards/check_snowflake_queries.sh`: each query runs, with the expected column names;
  - `node tests/dashboards/compare_snowflake_athena.mjs`: the same rows as the Athena originals, for a
    Snowflake and an Athena lakehouse loaded from the same logs bucket (also needs `athena_query.sh`'s
    AWS credentials and region);
  - `node tests/dashboards/compare_on_fixture.mjs`: the same rows as the Athena originals on a small
    fixture of edge cases, injected as CTEs (needs any Athena lakehouse's workgroup); the only check
    that covers findings and blocks when the test lake has none.
- the stub left at `terraform/aws` after the AWS (Athena) module moved to `terraform/aws/athena`
  (a configuration on the old path stops with the move message), and that the moved module and its
  example still validate, no AWS credentials: `tests/terraform/test_aws_moved_stub.sh`. Needs
  bash, Terraform 1.5 or newer, and network access for `terraform init` to download the aws provider.

Releases: see [RELEASING.md](RELEASING.md).

## Skill and dashboard docs
- Keep them agent-neutral: no agent-specific sections, notes or SQL branches. Name agents only in
  supported-agent lists (README, skill description). Where one agent's data differs, write a generic
  rule or fix the data upstream.
- Keep them short: add only what an agent needs to answer correctly, and state each rule once.
