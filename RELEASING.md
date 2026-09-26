# Releasing

- **Skill/plugin change** → bump `.claude-plugin/plugin.json` `version` (e.g. `1.0.0` → `1.0.1`).
  Claude Code caches installed plugins by version, so a same-version content change makes
  `claude plugin update` a no-op and customers keep the stale skill (they'd have to uninstall +
  reinstall). This version is independent of the git tag below.
- **Terraform module change** → in the PR, bump every `?ref=` pin in this repo to the new
  version; after merging to `main`, tag it on the merge commit (never move a tag customers
  already pin) and bump `MODULE_REF` in traceforce-ui `src/lib/lakehouseSnippet.ts`.
