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
- the Azure Databricks query script's read-only checks, offline, no cloud access:
  `tests/skill/test_databricks_query.sh`.

Releases: see [RELEASING.md](RELEASING.md).

## Skill and dashboard docs
- Keep them agent-neutral: no agent-specific sections, notes or SQL branches. Name agents only in
  supported-agent lists (README, skill description). Where one agent's data differs, write a generic
  rule or fix the data upstream.
- Keep them short: add only what an agent needs to answer correctly, and state each rule once.
