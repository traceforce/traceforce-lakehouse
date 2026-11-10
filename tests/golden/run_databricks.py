#!/usr/bin/env python3
"""Run the golden fixture through the Azure Databricks module's SQL
(terraform/azure/databricks/sql) on a SQL warehouse and compare with expected/ (AWS's output).

    python3 tests/golden/run_databricks.py [--out DIR]   # DIR: also write this run's rows there

Environment:
    DATABRICKS_HOST          workspace host, e.g. adb-....azuredatabricks.net
    DATABRICKS_WAREHOUSE_ID  the SQL warehouse to run on
    GOLDEN_STORAGE_ACCOUNT   the logs storage account (ADLS Gen2) the raw external location covers
    GOLDEN_CONTAINER         its container (default: logs)
    GOLDEN_LOGS_PREFIX       the deployment's logs_prefix (default: empty); the fixture must sit
                             under it, inside the module's raw external location
    GOLDEN_CATALOG           the catalog to create a throwaway schema in (default: traceforce_lakehouse)

Needs the Azure CLI signed in and Terraform (to render the templates). The fixture is uploaded with
`az storage --auth-mode login`, so the signed-in identity needs Storage Blob Data Contributor on
the container and no account key is used; the Databricks token comes from
`az account get-access-token`. Uploads the fixture under <logs_prefix>/_golden/<run id>/agent=decoy/
in the container, creates the schema golden_<run id> with copies of the deployed tables (columns,
types, NOT NULL, format-version, read from Unity Catalog, so the deployment must be up to date with
the branch), runs the scripts, compares, and removes both.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid

import golden as g

AZURE_DATABRICKS_APP = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"
DEPLOYED_SCHEMA = "traceforce"  # the module's schema (local.schema_name)
EXPORTS = "_traceforce/lakehouse/exports"  # under the logs prefix, as the producer writes them

# Differences from AWS that are accepted; each is a choice, not an accident, and each cell must
# differ exactly as its rule (golden.RULES) allows.
KNOWN = {
    # Spark writes characters outside the Basic Multilingual Plane (the emoji) as UTF-8; AWS
    # escapes them as surrogate pairs. Same JSON value.
    ("telemetry/agent=AGENT_IDENTITY_CLAUDE_CODE/dt=@D0@/SERIAL-1/dev@example.com_0b5c1f6e-1d2a-4c3b-9e8f-7a6b5c4d3e2f/"
     "sess-1/@D0@_120000.123_11111111-1111-4111-8111-111111111111_logs.json.gz#user_prompt", "attrs_json"):
        "non_bmp_escape",
    # AWS's from_iso8601_timestamp keeps milliseconds; Databricks keeps the microseconds the
    # export wrote, as Snowflake does.
    ("a1", "updated_at"): "ms_truncation",
    ("a4", "created_at"): "ms_truncation",
}

H = os.environ.get("DATABRICKS_HOST", "")
WH = os.environ.get("DATABRICKS_WAREHOUSE_ID", "")
ACCOUNT = os.environ.get("GOLDEN_STORAGE_ACCOUNT", "")
CONTAINER = os.environ.get("GOLDEN_CONTAINER", "logs")
LOGS_PREFIX = os.environ.get("GOLDEN_LOGS_PREFIX", "").strip("/")
CATALOG = os.environ.get("GOLDEN_CATALOG", "traceforce_lakehouse")


def token():
    return subprocess.run(["az", "account", "get-access-token", "--resource", AZURE_DATABRICKS_APP,
                           "--query", "accessToken", "-o", "tsv"],
                          check=True, capture_output=True, text=True).stdout.strip()


TOKEN = None


def api(method, path, body=None):
    req = urllib.request.Request(f"https://{H}{path}", method=method,
                                 data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req) as r:
        return json.load(r)


def sql(statement, label, run_id=None):
    """run_id binds :run_id, as the jobs' task parameter does for the ingest and mirror scripts."""
    body = {"warehouse_id": WH, "statement": statement, "wait_timeout": "50s", "on_wait_timeout": "CONTINUE"}
    if run_id is not None:
        body["parameters"] = [{"name": "run_id", "value": run_id}]
    r = api("POST", "/api/2.0/sql/statements", body)
    while r["status"]["state"] in ("PENDING", "RUNNING"):
        time.sleep(3)
        r = api("GET", f"/api/2.0/sql/statements/{r['statement_id']}")
    if r["status"]["state"] != "SUCCEEDED":
        raise SystemExit(f"{label} failed: {r['status'].get('error', {}).get('message', r['status'])}")
    cols = [c["name"] for c in r.get("manifest", {}).get("schema", {}).get("columns", [])]
    rows = [dict(zip(cols, row)) for row in (r.get("result", {}) or {}).get("data_array", []) or []]
    # large results come in further chunks
    nxt = (r.get("result") or {}).get("next_chunk_internal_link")
    while nxt:
        c = api("GET", nxt)
        rows += [dict(zip(cols, row)) for row in c.get("data_array", []) or []]
        nxt = c.get("next_chunk_internal_link")
    return rows


def deployed_ddl(table, cols, schema):
    """CREATE TABLE for a scratch copy of the deployed table: its columns, types, NOT NULL and
    format-version as Unity Catalog reports them, so the test runs against what tables.tf
    created. Managed Iceberg supports neither CREATE TABLE ... LIKE nor SHOW CREATE TABLE."""
    t = api("GET", f"/api/2.1/unity-catalog/tables/{CATALOG}.{DEPLOYED_SCHEMA}.{table}")
    if cols is not None and [c["name"] for c in t["columns"]] != [n for n, _, _ in cols]:
        raise SystemExit(f"{CATALOG}.{DEPLOYED_SCHEMA}.{table} doesn't match columns.json: apply "
                         "this branch to the deployment before running the golden test")
    columns = ", ".join(f"`{c['name']}` {c['type_text']}{'' if c['nullable'] else ' NOT NULL'}"
                        for c in t["columns"])
    return (f"CREATE TABLE {schema}.{table} ({columns}) USING ICEBERG "
            f"TBLPROPERTIES ('format-version' = '{t['properties']['format-version']}')")


def render_sql(inputs):
    """The job SQL from terraform/azure/databricks/render_sql, the module ingest.tf calls."""
    with tempfile.TemporaryDirectory() as d:
        json.dump(inputs, open(os.path.join(d, "inputs.json"), "w"))
        open(os.path.join(d, "main.tf"), "w").write(
            'locals {\n  inputs = jsondecode(file("inputs.json"))\n}\n'
            'module "sql" {\n  source             = %s\n'
            '  agent_events_table = local.inputs.agent_events_table\n'
            '  mirror_tables      = local.inputs.mirror_tables\n'
            '  runs_table         = local.inputs.runs_table\n'
            '  run_log_since      = local.inputs.run_log_since\n'
            '  logs_root          = local.inputs.logs_root\n'
            '  lookback_days      = local.inputs.lookback_days\n}\n'
            'output "ingest_sql" {\n  value = module.sql.ingest_sql\n}\n'
            'output "mirror_sql" {\n  value = module.sql.mirror_sql\n}\n'
            'output "freshness_view_sql" {\n  value = module.sql.freshness_view_sql\n}\n'
            # relative, not absolute: Terraform copies an absolute module path on its own, and
            # render_sql's ../ references (the schema module, the templates) would then not resolve.
            # realpath: on macOS the temp dir is under /var, a link to /private/var.
            % json.dumps(os.path.relpath(os.path.join(g.REPO, "terraform", "azure", "databricks",
                                                      "render_sql"), os.path.realpath(d))))
        for cmd in (["init", "-input=false"], ["apply", "-auto-approve", "-input=false"]):
            subprocess.run(["terraform", *cmd], cwd=d, check=True, capture_output=True)
        out = json.loads(subprocess.run(["terraform", "output", "-json"], cwd=d, check=True,
                                        capture_output=True, text=True).stdout)
        return {k: v["value"] for k, v in out.items()}


def upload(local, prefix):
    subprocess.run(["az", "storage", "fs", "directory", "upload", "--only-show-errors",
                    "--auth-mode", "login", "--account-name", ACCOUNT, "-f", CONTAINER,
                    "-s", os.path.join(local, "*"), "-d", prefix, "--recursive"],
                   check=True, capture_output=True)


def remove(prefix):
    """Delete the run's folder. A failure is reported, not raised, so it never hides the error
    that ended the run."""
    r = subprocess.run(["az", "storage", "fs", "directory", "delete", "--only-show-errors", "-y",
                        "--auth-mode", "login", "--account-name", ACCOUNT, "-f", CONTAINER,
                        "-n", prefix],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"WARNING: could not delete {CONTAINER}/{prefix} in {ACCOUNT}; remove it by hand: "
              f"{(r.stderr or r.stdout).strip()[:300]}")


def main():
    global TOKEN
    if not (H and WH and ACCOUNT):
        raise SystemExit("set DATABRICKS_HOST, DATABRICKS_WAREHOUSE_ID and GOLDEN_STORAGE_ACCOUNT")
    TOKEN = token()
    run = uuid.uuid4().hex[:8]
    # Under the deployment's logs_prefix: the raw external location covers only that prefix. The
    # run's own folder holds everything it writes, so cleanup removes it whole; the decoy agent=
    # folder inside it checks that agent is read from directly under the telemetry root.
    run_dir = f"{LOGS_PREFIX + '/' if LOGS_PREFIX else ''}_golden/{run}"
    prefix = f"{run_dir}/agent=decoy"
    root = f"abfss://{CONTAINER}@{ACCOUNT}.dfs.core.windows.net/{prefix}/"
    telemetry_root = f"{root}telemetry/"  # source_object must start with exactly this
    schema = f"{CATALOG}.golden_{run}"
    today = g.utc_today()
    tokens = g.day_tokens(today)
    print(f"run {run}: {root} -> {schema}")

    # Rendered by the module's own render_sql, as ingest.tf does; only the tables, the root and
    # the fixture's lookback are the test's.
    rendered = render_sql({"agent_events_table": f"{schema}.agent_events",
                           "mirror_tables": {t: f"{schema}.{t}" for t in g.MIRRORS},
                           "runs_table": f"{schema}._ingest_runs",
                           "run_log_since": time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime()),
                           "logs_root": root, "lookback_days": g.LOOKBACK_DAYS})
    ingest = rendered["ingest_sql"]
    mirror_sql = rendered["mirror_sql"]
    runs = []  # the run IDs passed, in order: each completed script logs one row under its own

    def dump(table, cols):
        sel = ", ".join(f"CAST(`{n}` AS STRING) AS `{n}`" for n, _, _ in cols)
        return sql(f"SELECT {sel} FROM {schema}.{table}", f"dump {table}")

    def mirror():  # every table in g.MIRRORS, as the daily job does
        runs.append(f"mirror-{len(runs)}")
        for table in g.MIRRORS:
            sql(mirror_sql[table], f"mirror {table}", runs[-1])

    try:
        with tempfile.TemporaryDirectory() as d:
            g.lay_out(d, tokens, phase=1)
            # export snapshots where the producer writes them (EXPORT_CONTRACT.md)
            os.makedirs(os.path.join(d, EXPORTS, ".."), exist_ok=True)
            os.rename(os.path.join(d, "exports"), os.path.join(d, EXPORTS))
            upload(d, prefix)
        sql(f"CREATE SCHEMA {schema}", "schema")
        for table, cols in (("agent_events", g.AGENT_EVENTS), *g.MIRRORS.items(), ("_ingest_runs", None)):
            sql(deployed_ddl(table, cols, schema), f"create {table}")
        t0 = time.time()
        sql(ingest, "ingest", "ingest-1")
        print(f"ingest: {time.time() - t0:.1f}s")
        events = g.normalise(dump("agent_events", g.AGENT_EVENTS), g.AGENT_EVENTS, tokens,
                             telemetry_root)
        t0 = time.time()
        sql(ingest, "ingest re-run", "ingest-2")
        print(f"ingest re-run: {time.time() - t0:.1f}s")
        again = g.normalise(dump("agent_events", g.AGENT_EVENTS), g.AGENT_EVENTS, tokens,
                            telemetry_root)
        mirror()  # day 1 into an empty table: inserts a1, a2, a3
        day1 = g.normalise(dump(g.MIRROR_TABLE, g.MIRROR), g.MIRROR, tokens)

        def add(phase):
            with tempfile.TemporaryDirectory() as d:
                g.lay_out(d, tokens, phase=phase)
                upload(os.path.join(d, "exports"), f"{prefix}/{EXPORTS}")

        add(2)  # day 2, now the newest
        mirror()  # updates a1, keeps a2, deletes a3, inserts a4
        mirrored = g.normalise(dump(g.MIRROR_TABLE, g.MIRROR), g.MIRROR, tokens)
        add(3)  # broken newest snapshot
        mirror()
        after_broken = g.normalise(dump(g.MIRROR_TABLE, g.MIRROR), g.MIRROR, tokens)
        # the other tables, mirrored at every step: each from its only snapshot (or empty)
        others = {t: g.normalise(dump(t, g.MIRRORS[t]), g.MIRRORS[t], tokens) for t in g.OTHER_MIRRORS}
        add(4)  # malformed newest snapshot
        try:
            mirror()
            malformed_failed = False
        except SystemExit as e:  # must fail reading agents' malformed file, not elsewhere
            # (MALFORMED_RECORD_IN_PARSING for a gzipped file, FAILED_READ_FILE for a plain one)
            malformed_failed = (str(e).startswith(f"mirror {g.MIRROR_TABLE} failed")
                                and ("MALFORMED_RECORD_IN_PARSING" in str(e)
                                     or "FAILED_READ_FILE" in str(e)))
        after_malformed = g.normalise(dump(g.MIRROR_TABLE, g.MIRROR), g.MIRROR, tokens)
        run_log = sql(f"SELECT table_name, run_id, listed_path, merged, rows_merged, mirror_rows, "
                      f"rows_inserted, upload_files, newest_upload_at FROM {schema}._ingest_runs", "run log")
        sql(f"CREATE VIEW {schema}.freshness AS {rendered['freshness_view_sql']}", "freshness view")
        freshness = sql(f"SELECT table_name, stale, reason FROM {schema}.freshness", "freshness")
    finally:
        # Independent: the uploaded files leave the customer's logs container even if dropping
        # the schema fails.
        try:
            sql(f"DROP SCHEMA IF EXISTS {schema} CASCADE", "cleanup schema")
        finally:
            remove(run_dir)
    g.check_same_day(today)

    if "--out" in sys.argv:  # keep this run's rows for inspection
        out = sys.argv[sys.argv.index("--out") + 1]
        g.write_rows(os.path.join(out, "agent_events.jsonl"), events)
        g.write_rows(os.path.join(out, f"{g.MIRROR_TABLE}_day1.jsonl"), day1)
        g.write_rows(os.path.join(out, f"{g.MIRROR_TABLE}.jsonl"), mirrored)
        for t, rows in others.items():
            g.write_rows(os.path.join(out, f"{t}.jsonl"), rows)
    bad = 0
    if again != events:
        print("re-run changed agent_events (not idempotent)")
        bad += 1
    if after_broken != mirrored:
        print("broken newest snapshot changed the mirror")
        bad += 1
    if not malformed_failed:
        print("the malformed newest snapshot did not fail the mirror")
        bad += 1
    if after_malformed != after_broken:
        print("the malformed newest snapshot changed the mirror")
        bad += 1
    # The run log: one row per completed script (the malformed run failed, so it logged nothing),
    # and the freshness view: one row per table.
    ingest_log = sorted((r for r in run_log if r["table_name"] == "agent_events"), key=lambda r: r["run_id"])
    if [r["run_id"] for r in ingest_log] != ["ingest-1", "ingest-2"]:
        print(f"run log: ingest rows {[r['run_id'] for r in ingest_log]}, expected ingest-1, ingest-2")
        bad += 1
    elif not (int(ingest_log[0]["rows_inserted"]) == len(events) and int(ingest_log[1]["rows_inserted"]) == 0
              and int(ingest_log[0]["upload_files"]) > 0 and ingest_log[0]["newest_upload_at"]):
        print(f"run log: ingest rows {ingest_log}")
        bad += 1
    # The last round stops at the malformed snapshot (the mirror table fails): the tables before it
    # in g.MIRRORS logged that round, it and the ones after it didn't run.
    order = list(g.MIRRORS)
    for t in order:
        got = sorted(r["run_id"] for r in run_log if r["table_name"] == t)
        want = runs if order.index(t) < order.index(g.MIRROR_TABLE) else runs[:-1]
        if got != want:
            print(f"run log: {t} rows {got}, expected {want}")
            bad += 1
    # What each mirror run logged, from the fixture: the end of the newest snapshot path in the
    # window, merged, rows_merged (rows the MERGE wrote: updated, inserted and deleted) and the
    # mirror's rows after. agents: day 1 inserts a1-a3; day 2 updates a1 and a2, deletes a3 and
    # inserts a4; the broken newest snapshot has no id, so nothing merges and the mirror keeps 3.
    # agent_conversation_files rewrites its 9 rows each round; issue_type_controls has no snapshot
    # in the window.
    day = {n: tokens[f"@D{n}-@"] for n in ("0", "-1", "-7")}
    want_log = {(g.MIRROR_TABLE, runs[0]): (f"dt={day['-1']}/110000.jsonl.gz", "true", "3", "3"),
                (g.MIRROR_TABLE, runs[1]): (f"dt={day['0']}/110000.jsonl.gz", "true", "4", "3"),
                (g.MIRROR_TABLE, runs[2]): (f"dt={day['0']}/130000.jsonl.gz", "false", None, "3")}
    for r in runs[:-1]:
        want_log[(g.LONG_TABLE, r)] = (f"dt={day['-7']}/110000.jsonl.gz", "true", "9", "9")
        want_log[(g.STALE_TABLE, r)] = (None, "false", None, "0")
    got_log = {(r["table_name"], r["run_id"]):
               ("/".join(r["listed_path"].split("/")[-2:]) if r["listed_path"] else None,
                r["merged"], r["rows_merged"], r["mirror_rows"])
               for r in run_log if r["table_name"] in g.MIRRORS}
    for k in sorted(set(want_log) | set(got_log)):
        if got_log.get(k) != want_log.get(k):
            print(f"run log {k}: (listed, merged, rows_merged, mirror_rows) {got_log.get(k)}, "
                  f"expected {want_log.get(k)}")
            bad += 1
    # Each table's stale flag and reason, from the fixture: the ingest just ran; agents' last logged
    # run read the broken newest snapshot (rows, no id), so its mirror keeps the older rows;
    # agent_conversation_files' only snapshot is 7 days old; issue_type_controls' only snapshot is
    # outside the 8-day window.
    want_fresh = {
        "agent_events": ("false", None),
        g.MIRROR_TABLE: ("true", "newest snapshot has no rows to merge; the mirror keeps its older rows"),
        g.LONG_TABLE: ("true", f"newest snapshot is from {tokens['@D-7-@']}"),
        g.STALE_TABLE: ("true", "no snapshot in the last 8 days"),
    }
    got_fresh = {r["table_name"]: (r["stale"], r["reason"]) for r in freshness}
    if len(freshness) != len(got_fresh) or got_fresh != want_fresh:
        for t in sorted(set(want_fresh) | set(got_fresh)):
            if got_fresh.get(t) != want_fresh.get(t):
                print(f"freshness {t}: (stale, reason) {got_fresh.get(t)}, expected {want_fresh.get(t)}")
        bad += 1
    bad += g.diff("agent_events", g.read_rows(os.path.join(g.EXPECTED, "agent_events.jsonl")), events, KNOWN)
    bad += g.diff(f"{g.MIRROR_TABLE}_day1", g.read_rows(os.path.join(g.EXPECTED, f"{g.MIRROR_TABLE}_day1.jsonl")), day1, KNOWN)
    bad += g.diff(g.MIRROR_TABLE, g.read_rows(os.path.join(g.EXPECTED, f"{g.MIRROR_TABLE}.jsonl")), mirrored, KNOWN)
    for t, rows in others.items():
        bad += g.diff(t, g.read_rows(os.path.join(g.EXPECTED, f"{t}.jsonl")), rows, KNOWN)
    print("PASS" if not bad else f"FAIL ({bad})")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
