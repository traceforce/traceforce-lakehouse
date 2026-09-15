# Changelog

## 1.0.0 (unreleased; tagged on merge)

First release. Terraform module (S3 Tables + hourly Athena ingest of the day-partitioned
activity logs written by TraceForce collector 1.0.42+, daily mirrors of TraceForce metadata),
Claude Code skill, export contract. AWS only; early access.

Releasing: tag the merge commit (`git tag 1.0.0 && git push --tags`); the README example pins
`?ref=1.0.0`. Customers upgrade by changing the ref.
