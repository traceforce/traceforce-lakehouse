# Changelog

## 1.0.0 (2026-09-15)

First release. Terraform module (S3 Tables + hourly Athena ingest of the day-partitioned
activity logs, daily mirrors of TraceForce metadata),
Claude Code skill, export contract. AWS only; early access. Validated end to end in a
development account: ingested rows equal an independent parse of the raw objects on every
column, mirrors equal their source row for row, partition pruning confirmed.

Releasing: tag the merge commit (`git tag 1.0.0 && git push --tags`); the README example pins
`?ref=1.0.0`. Customers upgrade by changing the ref.
