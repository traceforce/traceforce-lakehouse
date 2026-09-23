# Export contract: TraceForce metadata snapshots

Producer: TraceForce's export job, run daily around 04:00 UTC for every org with a CONNECTED
S3 or GCS Storage Provider (Azure follows with its lakehouse module).
Consumer: the lakehouse module's daily MERGE/DELETE — the `export_<table>` Glue tables on AWS
(Athena), or the external tables on GCP (BigQuery).

## Location

```
<bucket>/<prefix>/_traceforce/lakehouse/exports/<table>/dt=YYYY-MM-DD/<HHMMSS>.jsonl.gz
```

- `dt` and `HHMMSS` are UTC at the start of the run (around 04:00 UTC; the consumer merges at
  06:30 UTC, so a later file is merged the next day or on a manual `{"job":"exports"}` run). A manual re-run the same day writes a
  second file; the consumer takes the lexically greatest path among the files with at least one
  row within the last 7 days of `dt` (see the empty-file note below), so the newest file wins and
  nothing is ever overwritten or deleted. Failures are not
  retried automatically; the next daily run supersedes them.
- Permissions: the job runs under the TraceForce role the customer's Storage Provider grant
  already trusts and only ever calls PutObject on a new key; it never overwrites or deletes.
- One file per table per run (gzip, JSON Lines, UTF-8). An empty table still writes a
  zero-line file, but Athena reads no rows from it, so the newest non-empty file stays the
  effective snapshot: a table that genuinely drops to zero rows keeps its stale mirror rows
  until it has a row again (see `terraform/sql/mirror_export_delete.sql.tftpl`).

## Content

- One JSON object per line, keys = TraceForce's database column names, values as JSON
  encodes them: strings, numbers, booleans, `null`; `timestamptz` as RFC 3339 with offset
  (`2026-09-14T04:00:12.345678+00:00`); `uuid` as string; `jsonb` objects/arrays and SQL arrays
  **as JSON text (a string)**, not nested JSON, so the consumer can keep them as one string
  column. A `jsonb` column holding a bare scalar (none exist today) is exported as that scalar.
  The consumer parses timestamps with `from_iso8601_timestamp`, so the mirror keeps
  millisecond precision; TraceForce's database microseconds are truncated.
- Rows: `SELECT * FROM <table> WHERE org_id = $org` for tenant tables; whole table for
  `agent_catalog`, `mcp_catalog` and `mcp_categories` (global, no `org_id` column). Soft-deleted rows
  (`deleted_at` set) are included; consumers filter.
- Extra columns are ignored by the consumer; missing columns read as NULL. Adding a column
  to TraceForce's database therefore never breaks the mirror; exposing it in Iceberg is a one-line
  Terraform change (`export_tables` in `terraform/exports.tf`).

## Decoded enum columns

The producer decodes integer proto-enum columns to human-readable text at export time: it calls
the proto enum's `String()`, strips the enum-name prefix, and lowercases the result (e.g.
`SENSITIVE_DATA_CATEGORY_CREDENTIALS` -> `credentials`). Array enum columns are decoded
element-wise into a JSON text array (e.g. `["remote","local"]`). These columns are therefore
`string` in the mirror, not integers.

Decoded columns (`[]` = JSON text array):

- `connector_containment_findings`: `op`, `outcome`, `finding_status`
- `sensitive_data_findings`: `category`, `type`, `finding_status`
- `sandboxes`: `runtime_type`
- `agent_accounts`: `plan`
- `agent_instances`: `agent_deployment`
- `mcp_catalog`: `source_type`, `execution_environment[]`, `authentication_methods[]`
- `org_mcp_catalog`: `source_type`, `execution_environment[]`, `authentication_methods[]`
- `mcp_server_instances`: `transport_type`, `transport_security_type`, `deployment_model`,
  `auth_type`, `distribution_channel`, `linked_plans[]`
- `mcp_servers`: `distribution_channels[]`, `auth_types[]`, `sandbox_runtime_types[]`
- `mcp_categories`: `resource_type`

`mcp_categories.resource_type` uses an explicit `ISSUE_DETAIL_MCP_RESOURCE_TYPE_` prefix, so it
reads `public` / `internal_apps`.

`agent_type` and `mcp_server_type` are NOT decoded: they stay integer join keys, resolved through
the catalogs (`agent_catalog`, `mcp_catalog` / `org_mcp_catalog`).

## Producer-side validation

Before writing a table, the export job checks that every column in this contract exists
in TraceForce's database with a compatible type. A mismatch fails the run for that table and is reported
to TraceForce; the previous snapshot stays the newest and the mirror keeps yesterday's rows.
Extra TraceForce's database columns are exported and ignored by the consumer.

## Tables (v1, 17)

| Group | Tables |
|---|---|
| Identity | devices, sandboxes, agent_accounts, agent_instances, agent_instances_accounts, device_owner_mappings |
| Agent names | agent_catalog (global) |
| Findings + bridge to logs | sensitive_data_findings, connector_containment_findings, agent_conversations, agent_conversation_files |
| MCP | mcp_server_instances, mcp_server_agent_instances, mcp_servers, mcp_catalog (global), org_mcp_catalog, mcp_categories (global) |

Deferred: user_groups / user_group_devices / user_group_members / idp_directory_users
(no data yet), agent_issues / mcp_server_issues + their lookup chain, policies +
their lookup chain, orgs.

## Sizing

A full daily snapshot of the largest single org is well under 100 MB gzipped; most tables
are a few thousand rows.
