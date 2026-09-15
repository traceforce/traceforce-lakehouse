# Changelog

## v0.2.0 (unreleased)

Day-partitioned ingest. The collector (release 1.0.42+) writes activity objects under
`conversations/<agent>/dt=<YYYYMMDD>/…`; the ingest now runs hourly over the last three day
folders instead of rescanning the whole prefix every 15 minutes, so cost and run time no
longer grow with history. `{"job":"ingest","lookback_days":N}` re-reads N days for catch-up.
Objects from older collectors (flat layout) are not read.

## v0.1.0 (2026-09-14)

First release. Terraform module (S3 Tables + Athena ingest of activity logs, daily mirrors of
TraceForce metadata), Claude Code skill, export contract. AWS only; early access.

Releasing: tag the commit (`git tag vX.Y.Z && git push --tags`) and update the `?ref=` in the
README example. Customers upgrade by changing the ref.
