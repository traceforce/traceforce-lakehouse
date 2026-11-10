#!/usr/bin/env python3
"""Run the golden fixture through the AWS module's SQL (terraform/aws/sql) in a local Trino, the
engine Athena engine version 3 is built on, and write or check expected/.

    python3 tests/golden/run_trino.py            # compare with expected/
    python3 tests/golden/run_trino.py --update   # rewrite expected/ from this run
    python3 tests/golden/run_trino.py --check-projection   # only check the copied AWS settings

Needs Docker and Terraform. Mirrors the AWS module's tables with the same storage formats: the
raw telemetry as a TEXTFILE table (LazySimpleSerDe, one document per line), the export snapshots
as OPENX_JSON tables with string columns, and Iceberg targets with the module's types. Athena's
partition projection doesn't exist in Trino, so the partitions the projection would expose are
registered explicitly: raw dt folders from the module's day_layout_since up to tomorrow, export dt
folders up to today. The ingest runs once per agent=... folder with lookback_days, as the state
machine does.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import uuid

import golden as g

IMAGE = "trinodb/trino:476"
# Unique per run, so overlapping runs never remove each other's Trino; the label finds leftovers
# from a run that was killed before its cleanup (see README).
NAME = f"traceforce-golden-trino-{uuid.uuid4().hex[:8]}"
LABEL = "traceforce-golden=1"
TELEMETRY_ROOT = "local:///telemetry/"  # the raw table's external_location, as "$path" reports it
# setup_tables registers the partitions Athena's projection in the AWS module would expose. These
# are its settings; check_projection() stops the run if the module's differ, so they're updated
# together.
DAY_LAYOUT_SINCE = "20260923"  # raw telemetry: first day (the end is tomorrow)
EXPORTS_SINCE = "2026-09-01"   # export snapshots: first day (the end is today)
PROJECTION = {
    "locals.tf": f'day_layout_since = "{DAY_LAYOUT_SINCE}"',
    "raw.tf": '"projection.dt.range" = "${local.day_layout_since},NOW+1DAYS"',
    "exports.tf": f'"projection.dt.range" = "{EXPORTS_SINCE},NOW"',
}
TRINO_TYPE = {"string": "varchar", "int": "integer", "long": "bigint", "double": "double",
              "boolean": "boolean", "timestamp": "timestamp(6)"}


def sh(*a, **k):
    return subprocess.run(a, check=True, capture_output=True, text=True, **k).stdout


def start(work):
    cat = os.path.join(work, "catalog")
    os.makedirs(cat)
    open(os.path.join(cat, "hive.properties"), "w").write(
        "connector.name=hive\nhive.metastore=file\nhive.metastore.catalog.dir=local:///metastore\n"
        "fs.native-local.enabled=true\nlocal.location=/data\nhive.recursive-directories=true\n"
        "hive.allow-register-partition-procedure=true\n")
    open(os.path.join(cat, "iceberg.properties"), "w").write(
        "connector.name=iceberg\niceberg.catalog.type=testing_file_metastore\n"
        "hive.metastore.catalog.dir=local:///iceberg_metastore\n"
        "fs.native-local.enabled=true\nlocal.location=/data\n")
    os.makedirs(os.path.join(work, "data"))
    # Run as the caller: Trino writes under the mounted /data, which belongs to the caller (on
    # Linux, the image's own uid 1000 can't write to it unless the caller is uid 1000).
    sh("docker", "run", "-d", "--name", NAME, "--label", LABEL, "-e", "TZ=UTC",
       "--user", f"{os.getuid()}:{os.getgid()}",
       "-v", f"{cat}:/etc/trino/catalog", "-v", f"{work}/data:/data", IMAGE)
    for _ in range(100):
        if subprocess.run(["docker", "exec", NAME, "trino", "--execute", "SELECT 1"],
                          capture_output=True).returncode == 0:
            return
        time.sleep(3)
    raise SystemExit("Trino did not start")


def trino(work, sql, label):
    """Run statements (one session) from a file; return the JSON rows of the last result."""
    path = os.path.join(work, "data", "stmt.sql")
    open(path, "w").write(sql)
    r = subprocess.run(["docker", "exec", NAME, "trino", "--output-format=JSON", "--file", "/data/stmt.sql"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"{label} failed:\n{r.stderr[-3000:]}")
    return [json.loads(l) for l in r.stdout.splitlines() if l.startswith("{")]


def q(s):
    return "'{}'".format(s.replace("'", "''"))


def check_projection():
    for f, setting in PROJECTION.items():
        text = " ".join(open(os.path.join(g.REPO, "terraform", "aws", f)).read().split())
        if setting not in text:
            raise SystemExit(f"terraform/aws/{f} no longer has {setting}: update the partition "
                             "settings at the top of run_trino.py to match")


def setup_tables(work, tokens):
    tomorrow = tokens["@D+1@"]
    stmts = ["CREATE SCHEMA hive.lake WITH (location = 'local:///lake/')",
             "CREATE TABLE hive.lake.raw_telemetry (doc varchar, agent varchar, dt varchar) "
             "WITH (format = 'TEXTFILE', external_location = 'local:///telemetry/', partitioned_by = ARRAY['agent', 'dt'])",
             "CREATE SCHEMA iceberg.lake WITH (location = 'local:///iceberg/')"]
    for table, cols in g.MIRRORS.items():
        stmts.append(f"CREATE TABLE hive.lake.export_{table} ("
                     + ", ".join(f"{n} varchar" for n, _, _ in cols)
                     + f", dt varchar) WITH (format = 'OPENX_JSON', external_location = 'local:///exports/{table}/', "
                       "partitioned_by = ARRAY['dt'])")
    for table, cols in (("agent_events", g.AGENT_EVENTS), *g.MIRRORS.items()):
        stmts.append(f"CREATE TABLE iceberg.lake.{table} ("
                     + ", ".join(f"{n} {TRINO_TYPE[t]}{' NOT NULL' if req else ''}" for n, t, req in cols)
                     + ") WITH (format_version = 2)")
    # the partitions Athena's projection would expose
    raw = os.path.join(work, "data", "telemetry")
    for a in sorted(os.listdir(raw)):
        for d in sorted(os.listdir(os.path.join(raw, a))):
            agent, day = a.split("=", 1)[1], d.split("=", 1)[1]
            if DAY_LAYOUT_SINCE <= day <= tomorrow:
                stmts.append(f"CALL hive.system.register_partition('lake', 'raw_telemetry', "
                             f"ARRAY['agent', 'dt'], ARRAY[{q(agent)}, {q(day)}])")
    for table in g.MIRRORS:
        exp = os.path.join(work, "data", "exports", table)
        for d in sorted(os.listdir(exp)):
            day = d.split("=", 1)[1]
            if EXPORTS_SINCE <= day <= tokens["@D0-@"]:
                stmts.append(f"CALL hive.system.register_partition('lake', 'export_{table}', "
                             f"ARRAY['dt'], ARRAY[{q(day)}])")
    trino(work, ";\n".join(stmts) + ";\n", "setup")
    return [a.split("=", 1)[1] for a in sorted(os.listdir(raw))]


def ingest(work, agents):
    sql = g.render("terraform/aws/sql/ingest_agent_events.sql.tftpl", {
        "target": "iceberg.lake.agent_events", "raw": "hive.lake.raw_telemetry",
        "cols": ", ".join(n for n, _, _ in g.AGENT_EVENTS)})
    for a in agents:
        trino(work, f"PREPARE ingest FROM\n{sql};\nEXECUTE ingest USING {q(a)}, {g.LOOKBACK_DAYS}, {g.LOOKBACK_DAYS};\n",
              f"ingest {a}")


def mirror(work):
    """Mirror every table in g.MIRRORS, as the daily job does."""
    for table, mcols in g.MIRRORS.items():
        cols = [{"name": n, "type": t} for n, t, _ in mcols]
        v = {"target": f"iceberg.lake.{table}", "source": f"hive.lake.export_{table}"}
        merge = g.render("terraform/aws/sql/mirror_export_merge.sql.tftpl", {**v, "columns": cols})
        delete = g.render("terraform/aws/sql/mirror_export_delete.sql.tftpl", v)
        trino(work, merge + ";\n", f"merge {table}")
        trino(work, delete + ";\n", f"delete {table}")


def dump(work, table, cols):
    sel = ", ".join(f"CAST({n} AS varchar) AS {n}" for n, _, _ in cols)
    return trino(work, f"SELECT {sel} FROM iceberg.lake.{table};\n", f"dump {table}")


def main():
    check_projection()
    if "--check-projection" in sys.argv:  # the pre-commit hook: only this check, no Trino
        return
    update = "--update" in sys.argv
    today = g.utc_today()
    tokens = g.day_tokens(today)
    with tempfile.TemporaryDirectory(prefix="golden-trino-") as work:
        try:
            start(work)
            g.lay_out(os.path.join(work, "data"), tokens, phase=1)
            # Athena's projection sees every day in its range; here a dt folder must exist to be
            # registered, and day 2's (today) is only laid out after the first mirror run.
            os.makedirs(os.path.join(work, "data", "exports", g.MIRROR_TABLE, f"dt={tokens['@D0-@']}"),
                        exist_ok=True)
            agents = setup_tables(work, tokens)
            ingest(work, agents)
            events = g.normalise(dump(work, "agent_events", g.AGENT_EVENTS), g.AGENT_EVENTS, tokens,
                                 TELEMETRY_ROOT)
            ingest(work, agents)  # re-run: must add nothing
            again = g.normalise(dump(work, "agent_events", g.AGENT_EVENTS), g.AGENT_EVENTS, tokens,
                                 TELEMETRY_ROOT)
            mirror(work)  # day 1 into an empty table: inserts a1, a2, a3
            day1 = g.normalise(dump(work, g.MIRROR_TABLE, g.MIRROR), g.MIRROR, tokens)
            g.lay_out(os.path.join(work, "data"), tokens, phase=2)  # day 2, now the newest
            mirror(work)  # updates a1, keeps a2, deletes a3, inserts a4
            mirrored = g.normalise(dump(work, g.MIRROR_TABLE, g.MIRROR), g.MIRROR, tokens)
            g.lay_out(os.path.join(work, "data"), tokens, phase=3)  # broken newest snapshot
            mirror(work)
            after_broken = g.normalise(dump(work, g.MIRROR_TABLE, g.MIRROR), g.MIRROR, tokens)
            # the other tables, mirrored at every step: each from its only snapshot (or empty)
            others = {t: g.normalise(dump(work, t, g.MIRRORS[t]), g.MIRRORS[t], tokens)
                      for t in g.OTHER_MIRRORS}
            g.lay_out(os.path.join(work, "data"), tokens, phase=4)  # malformed newest snapshot
            try:
                mirror(work)
                malformed_failed = False
            except SystemExit as e:  # must fail on agents' malformed file, not elsewhere
                malformed_failed = str(e).startswith(f"merge {g.MIRROR_TABLE} failed")
            after_malformed = g.normalise(dump(work, g.MIRROR_TABLE, g.MIRROR), g.MIRROR, tokens)
        finally:
            subprocess.run(["docker", "rm", "-f", NAME], capture_output=True)
    g.check_same_day(today)
    bad = 0
    if again != events:
        print("re-run changed agent_events (not idempotent)")
        bad += 1
    if not malformed_failed:
        # Simulation difference, not an AWS bug: Trino's OPENX_JSON reads a malformed line as an
        # all-NULL row, so the guard skips the MERGE and the run succeeds. Athena's OpenX SerDe
        # fails it (ignore.malformed.json defaults to false, exports.tf). Only "unchanged" is
        # checked here.
        print("simulation difference: Trino read the malformed newest snapshot as NULL rows "
              "(Athena fails it); the mirror is unchanged")
    if after_malformed != after_broken:
        print("the malformed newest snapshot changed the mirror")
        bad += 1
    if after_broken != mirrored:
        # Known AWS issue: its delete guard looks at the whole 7-day window, not the newest file,
        # so a newest snapshot without ids deletes every row. Snowflake and Databricks scope the
        # guard to the newest file and pass this check.
        print(f"known AWS issue: the broken newest snapshot left {len(after_broken)} of "
              f"{len(mirrored)} {g.MIRROR_TABLE} rows")
    if update:
        g.write_rows(os.path.join(g.EXPECTED, "agent_events.jsonl"), events)
        g.write_rows(os.path.join(g.EXPECTED, f"{g.MIRROR_TABLE}_day1.jsonl"), day1)
        g.write_rows(os.path.join(g.EXPECTED, f"{g.MIRROR_TABLE}.jsonl"), mirrored)
        for t, rows in others.items():
            g.write_rows(os.path.join(g.EXPECTED, f"{t}.jsonl"), rows)
        print(f"wrote expected/: {len(events)} agent_events rows, {len(day1)} then {len(mirrored)} "
              f"{g.MIRROR_TABLE} rows, " + ", ".join(f"{len(r)} {t} rows" for t, r in others.items()))
    else:
        bad += g.diff("agent_events", g.read_rows(os.path.join(g.EXPECTED, "agent_events.jsonl")), events)
        bad += g.diff(f"{g.MIRROR_TABLE}_day1", g.read_rows(os.path.join(g.EXPECTED, f"{g.MIRROR_TABLE}_day1.jsonl")), day1)
        bad += g.diff(g.MIRROR_TABLE, g.read_rows(os.path.join(g.EXPECTED, f"{g.MIRROR_TABLE}.jsonl")), mirrored)
        for t, rows in others.items():
            bad += g.diff(t, g.read_rows(os.path.join(g.EXPECTED, f"{t}.jsonl")), rows)
    print("PASS" if not bad else f"FAIL ({bad})")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
