# Releasing

- **Skill/plugin change** → bump `.claude-plugin/plugin.json` `version` (e.g. `1.0.0` → `1.0.1`).
  Claude Code caches installed plugins by version, so a same-version content change makes
  `/plugin update` a no-op and customers keep the stale skill (they'd have to uninstall +
  reinstall). This version is independent of the git tag below.
- **Terraform module change** → after merging to `main`, move the `1.0.0` tag to the merge
  commit; the customer snippet pins `?ref=1.0.0`, and customers pick it up with
  `terraform init -upgrade`.
