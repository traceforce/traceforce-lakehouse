# Golden test: ingest and mirror SQL

Proves that the engines turn the same raw files into the same rows. One fixture of OTLP telemetry
and export snapshots goes through each cloud's SQL; the rows are compared as text with
`expected/`, which is AWS's output.

| File | What |
|---|---|
| `fixture/raw/telemetry/...` | OTLP log and span objects in scout's folder layout, with the AnyValue edge cases (below) |
| `fixture/exports/agents/...` | day 1 of `agents` (`a1`, `a2`, `a3`) and a future-dated snapshot that must never win |
| `fixture/exports/agent_conversation_files/...` | one snapshot of `agent_conversation_files`, dated `D-7` (the oldest day the mirror reads), for the `long` type `agents` lacks: `size_bytes` above 32 bits, at and beyond the 64-bit limit, negative, `1.5`, `1e3`, a quoted number, a non-number and `null` |
| `fixture/exports/issue_type_controls/...` | one snapshot, dated `D-8` (one day beyond the mirror's window): never read, so the mirror stays empty and the run succeeds |
| `fixture/exports_day2/...` | day 2, added after the mirror has run on day 1: `a1` changed, `a3` gone, `a4` new, so the MERGE updates, deletes and inserts |
| `fixture/exports_phase2/...` | a broken newest snapshot (a row without an id), added after day 2 |
| `fixture/exports_phase4/...` | a malformed newest snapshot (not JSON), added last: the mirror run must fail and change nothing |
| `make_fixture.py` | writes `fixture/` (`python3 make_fixture.py fixture`); edit this, not the files |
| `expected/` | the AWS SQL's output for the fixture, from `run_trino.py --update`: `agents_day1.jsonl` after day 1, `agents.jsonl` after day 2, `agent_conversation_files.jsonl` and `issue_type_controls.jsonl` (empty) at the end |
| `run_trino.py` | runs `terraform/aws/sql` in a local Trino (the engine Athena engine version 3 is built on) |
| `run_databricks.py` | runs `terraform/azure/databricks/sql` on a Databricks SQL warehouse |
| `golden.py` | shared: lays out the fixture for today's date, renders templates with Terraform, normalises rows |

Paths in the fixture use day tokens relative to the run date (UTC): `@D0@` is today as YYYYMMDD,
`@D0-@` today as YYYY-MM-DD, `@D-1@` yesterday, `@D+1@` tomorrow. The windows are checked at both
ends: today, yesterday, two days ago and tomorrow are read with `lookback_days = 3`; three days ago,
the day after tomorrow and five days ahead are not; a non-JSON object yields no rows and no error.

## Run

```sh
# AWS reference (Docker + Terraform)
python3 tests/golden/run_trino.py            # check expected/
python3 tests/golden/run_trino.py --update   # rewrite expected/ after a deliberate change

# Azure Databricks (Azure CLI signed in with Storage Blob Data Contributor on the container, + Terraform)
DATABRICKS_HOST=adb-....azuredatabricks.net DATABRICKS_WAREHOUSE_ID=<id> \
GOLDEN_STORAGE_ACCOUNT=<logs account> GOLDEN_LOGS_PREFIX=<logs_prefix, if any> \
python3 tests/golden/run_databricks.py
```

Each `run_trino.py` run starts its own container (`traceforce-golden-trino-<run id>`) and removes it
at the end. A run killed before its cleanup leaves it behind; remove leftovers with
`docker rm -f $(docker ps -aq --filter label=traceforce-golden=1)`.

`run_databricks.py` uploads the fixture under `<logs_prefix>/_golden/<run id>/agent=decoy/` in the
logs container (inside the module's raw external location, which covers only the deployment's
`logs_prefix`; the decoy `agent=` folder checks that `agent` is read from the right folder),
creates the schema `golden_<run id>` in the catalog with copies of the deployed `agent_events`,
`agents`, `agent_conversation_files` and `issue_type_controls` (columns, types, `NOT NULL` and
`format-version` read from Unity Catalog), and drops both when done. It stops if the deployed
columns don't match `columns.json`: apply the branch first. Each runner also checks that a re-run
of the ingest adds nothing, that the broken snapshot changes nothing, and that the malformed one
fails the mirror run without changing it.

## Edge cases covered

Attribute values: `intValue` as a string and a number, above 2^53 in both forms, and `1e2`;
`doubleValue` as `1.0`, `1`, `1.5`, `1.50`, `1e20`, `12345678.9`, `0.0001`, `"NaN"`, `"Infinity"`,
`"1.5"`; booleans; `bytesValue`, an empty AnyValue and `stringValue:null` (key kept, value null);
`IntValue` (wrong case: not a value); `arrayValue:{}`, empty `values` and a mixed array with a
nested kvlist; `kvlistValue:{}` and a kvlist with keys out of order, a duplicate key, a nested
kvlist, nested bytes and odd spacing; duplicate keys, an empty-string key, keys differing only in
case; quotes, backslashes, `/`, `é`, an emoji, a newline and ESC. Also: input tokens sent as
`42.0`, a token count above BIGINT, tool arguments as a kvlist with `mcp_server_name`, a record time
with sub-microsecond nanoseconds, a zero record time (observed time used), a record with no time
(upload time used), a span with start and end times, input tokens as an int and a generation id,
and a path with `+` and a space.

Mirror snapshot values: numbers that don't fit the column type, a non-number, offsets `+05:30` and
`-07:00`, `Z`, microseconds, a timestamp with a space instead of `T`, and a row without an id.

## Known differences

Accepted differences from `expected/`, listed in each runner:

| Engine | Difference |
|---|---|
| Databricks | Characters outside the Basic Multilingual Plane (emoji) are written as UTF-8 in `attrs_json`; AWS escapes them (`😀`). Same JSON value. |
| Databricks | Mirror timestamps keep microseconds; AWS keeps milliseconds. |
| AWS | A newest snapshot with rows but no ids deletes every mirror row: AWS's delete guard checks the whole 7-day window, not the newest file. The Databricks and Snowflake SQL scope it to the newest file. `run_trino.py` reports this rather than failing. |
| AWS (simulation only) | Trino's `OPENX_JSON` reads a malformed line as an all-NULL row, so the malformed snapshot doesn't fail the run there; Athena's OpenX SerDe fails it (`ignore.malformed.json` defaults to false). `run_trino.py` checks only that the mirror is unchanged. |

Not run here: Snowflake and GCP. Differences from AWS found earlier, not re-checked by this test: GCP renders `1.0` as `1`, loses
integers above 2^53 and orders keys differently; Snowflake drops null-valued keys.
