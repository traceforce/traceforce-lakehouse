# Releasing

- **Skill/plugin change** → bump `.claude-plugin/plugin.json` `version` (e.g. `1.0.0` → `1.0.1`).
  Claude Code caches installed plugins by version, so a same-version content change makes
  `claude plugin update` a no-op and customers keep the stale skill (they'd have to uninstall +
  reinstall). This version is independent of the git tag below.
- **Terraform module change** → in the PR, bump every `?ref=` pin in this repo to the new
  version; after merging to `main`, tag it on the merge commit (never move a tag customers
  already pin) and bump `MODULE_REF` in traceforce-ui `src/lib/lakehouseSnippet.ts`.
- **`columns.json` change to an existing table** → AWS and Azure (Snowflake and Databricks)
  recreate that table, empty until it is refilled. Any change counts, including appending a
  column. The release notes must name the recreated tables and the catch-up: a manual mirror
  run for the mirror tables, a `lookback_days` ingest for `agent_events`. The `agent_events`
  catch-up only reaches raw telemetry still in the customer's storage, so older history is lost
  for good. Prefer `attrs_json` over a new `agent_events` column. On Azure (Databricks) the
  `freshness` view still shows a recreated mirror as fresh until that catch-up mirror run (or the
  daily 12:30 UTC one); the release notes should say so.
