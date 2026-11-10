"""Shared helpers for the golden test: lay the fixture out for today's date, render the SQL
templates with Terraform, and normalise query results so every engine's output compares as text.

The fixture's paths use day tokens relative to the run date (UTC): @D0@ is today as YYYYMMDD
(raw telemetry folders and filenames), @D0-@ is today as YYYY-MM-DD (export folders); @D-1@ is
yesterday, @D+1@ tomorrow, and so on. Results are mapped back to the tokens before comparing.
"""
import datetime as dt
import gzip
import json
import math
import os
import re
import shutil
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
FIXTURE = os.path.join(HERE, "fixture")
EXPECTED = os.path.join(HERE, "expected")
SCHEMA = json.load(open(os.path.join(REPO, "terraform", "schema", "columns.json")))

LOOKBACK_DAYS = 3
# The mirrored export tables. agents (string, int, double, boolean, timestamp) goes through the
# MERGE's insert, update and delete. Each other table has one snapshot and is compared at the end:
# agent_conversation_files covers long, at the oldest day of the mirror's window;
# issue_type_controls has a snapshot only beyond the window, so its mirror stays empty.
MIRROR_TABLE = "agents"
LONG_TABLE = "agent_conversation_files"
STALE_TABLE = "issue_type_controls"

AGENT_EVENTS = [(c["name"], c["type"], c["required"]) for c in SCHEMA["agent_events"]]
MIRRORS = {t: [(c.split(":")[0], c.split(":")[1], c.split(":")[0] == "id")
               for c in SCHEMA["export_tables"][t]]
           for t in (MIRROR_TABLE, LONG_TABLE, STALE_TABLE)}
OTHER_MIRRORS = [t for t in MIRRORS if t != MIRROR_TABLE]
MIRROR = MIRRORS[MIRROR_TABLE]

# llm_model_prices, read by the ingest to estimate cost (USD per million tokens). The runners
# create it with these rows instead of mirroring a snapshot.
PRICES_TABLE = "llm_model_prices"
PRICES = [(c.split(":")[0], c.split(":")[1], c.split(":")[0] == "id") for c in SCHEMA["export_tables"][PRICES_TABLE]]
PRICE_ROWS = [
    {"id": "p1", "model_key": "gpt-golden", "input_usd_per_mtok": 2.0, "cache_read_usd_per_mtok": 0.2,
     "cache_write_usd_per_mtok": 2.5, "output_usd_per_mtok": 10.0, "source": "litellm", "source_ref": "golden"},
    {"id": "p2", "model_key": "gpt-golden-nocache", "input_usd_per_mtok": 1.0, "cache_read_usd_per_mtok": None,
     "cache_write_usd_per_mtok": None, "output_usd_per_mtok": 4.0, "source": "litellm", "source_ref": "golden"},
]


def price_values(literal):
    """VALUES rows for PRICE_ROWS in PRICES column order; literal(value, type) renders one value."""
    return ", ".join("(" + ", ".join(literal(r.get(n), t) for n, t, _ in PRICES) + ")" for r in PRICE_ROWS)


def day_tokens(today):
    """{token: value} for days -10..+10 around today."""
    out = {}
    for n in range(-10, 11):
        d = today + dt.timedelta(days=n)
        tag = "0" if n == 0 else f"{n:+d}"
        out[f"@D{tag}@"] = d.strftime("%Y%m%d")
        out[f"@D{tag}-@"] = d.strftime("%Y-%m-%d")
    return out


def utc_today():
    return dt.datetime.now(dt.timezone.utc).date()


def check_same_day(start):
    """The day tokens are fixed when a run starts, but the SQL reads the clock itself: a run that
    crosses 00:00 UTC compares (or, with --update, would write) rows for the wrong days. Stop
    before either."""
    if utc_today() != start:
        raise SystemExit(f"the run crossed 00:00 UTC ({start} -> {utc_today()}); run it again")


def _sub(s, tokens):
    return re.sub(r"@D[-+0-9]+-?@", lambda m: tokens[m.group(0)], s)


def lay_out(dst, tokens, phase):
    """Copy one phase of the fixture to dst with tokens resolved and data files gzipped, as the
    writers do: dst/telemetry/... for raw telemetry, dst/exports/<table>/dt=.../ for snapshots.
    Phase 1: the raw telemetry and the day-1 snapshots; phase 2: the day-2 snapshot (newest);
    phase 3: the broken newest snapshot; phase 4: the malformed newest snapshot. Each phase writes
    only its own files, so the mirror can run between them. Returns the relative paths written."""
    written = []
    trees = {1: [("raw", ""), ("exports", "exports")], 2: [("exports_day2", "exports")],
             3: [("exports_phase2", "exports")], 4: [("exports_phase4", "exports")]}[phase]
    for src_dir, dst_prefix in trees:
        root = os.path.join(FIXTURE, src_dir)
        for base, _, files in os.walk(root):
            for f in files:
                src = os.path.join(base, f)
                rel = _sub(os.path.relpath(src, root), tokens)
                rel = os.path.join(dst_prefix, rel) if dst_prefix else rel
                gz = f.endswith(".json") or f.endswith(".jsonl")
                out = os.path.join(dst, rel + (".gz" if gz else ""))
                os.makedirs(os.path.dirname(out), exist_ok=True)
                data = open(src, "rb").read()
                if gz:
                    with gzip.open(out, "wb") as g:
                        g.write(data)
                else:
                    shutil.copyfile(src, out)
                written.append(os.path.relpath(out, dst))
    return sorted(written)


def render(template, variables):
    """Render a .sql.tftpl with Terraform's templatefile(), exactly as the modules do."""
    with tempfile.TemporaryDirectory() as d:
        json.dump(variables, open(os.path.join(d, "vars.json"), "w"))
        open(os.path.join(d, "main.tf"), "w").write(
            'output "sql" {\n  value = templatefile(%s, jsondecode(file("vars.json")))\n}\n'
            % json.dumps(os.path.join(REPO, template)))
        subprocess.run(["terraform", "init", "-input=false"], cwd=d, check=True, capture_output=True)
        subprocess.run(["terraform", "apply", "-auto-approve", "-input=false"], cwd=d, check=True,
                       capture_output=True)
        return subprocess.run(["terraform", "output", "-raw", "sql"], cwd=d, check=True,
                              capture_output=True, text=True).stdout


def _ts(v):
    """Any engine's timestamp text -> 'YYYY-MM-DD HH:MM:SS.ffffff'."""
    m = re.fullmatch(r"(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?Z?", v)
    if not m:
        raise ValueError(f"unexpected timestamp text {v!r}")
    frac = (m.group(3) or "").ljust(6, "0")
    if len(frac) > 6:
        raise ValueError(f"timestamp finer than microseconds: {v!r}")
    return f"{m.group(1)} {m.group(2)}.{frac}"


def _double(v):
    f = float(v)
    return "NaN" if math.isnan(f) else repr(f)


def normalise(rows, columns, tokens, telemetry_root=None):
    """rows: [{column: value-as-text-or-None}] -> canonical rows, tokens restored, sorted.
    source_object must start with telemetry_root, the exact telemetry root the runner used; that
    root becomes "telemetry/" (a source_object under any other root fails the run rather than being
    cut to look right). ingested_at must be set and is then dropped (it is the run time)."""
    back = sorted(((v, k) for k, v in tokens.items()), key=lambda x: -len(x[0]))
    out = []
    for r in rows:
        n = {}
        for name, typ, _ in columns:
            v = r.get(name)
            if name == "ingested_at":
                if v is None:
                    raise ValueError("ingested_at is NULL")
                continue
            if v is not None:
                v = str(v) if not isinstance(v, bool) else ("true" if v else "false")
                if typ == "timestamp":
                    v = _ts(v)
                elif typ == "double":
                    v = _double(v)
                elif typ == "boolean":
                    v = v.lower()
                if name == "source_object":
                    if telemetry_root is None or not v.startswith(telemetry_root):
                        raise ValueError(f"source_object {v!r} is not under {telemetry_root!r}")
                    v = "telemetry/" + v[len(telemetry_root):]
                # Values derived from the run date go back to tokens. The fixture's fixed OTLP
                # times are in 2020, far from any run date, so they never collide with a token.
                if name in ("source_object", "upload_ts", "path_session", "ts", "end_ts"):
                    for val, tok in back:
                        v = v.replace(val, tok)
            n[name] = v
        out.append(n)
    key = lambda r: tuple("" if r.get(k) is None else str(r[k]) for k in
                          ("source_object", "id", "ts", "event_name", "span_name"))
    return sorted(out, key=key)


def write_rows(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False, sort_keys=False) + "\n")


def read_rows(path):
    return [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]


def _escape_non_bmp(text):
    """Write characters outside the Basic Multilingual Plane as JSON surrogate-pair escapes,
    as AWS's JSON functions do (U+1F600 -> \\uD83D\\uDE00)."""
    def esc(m):
        c = ord(m.group(0)) - 0x10000
        return "\\u%04X\\u%04X" % (0xD800 + (c >> 10), 0xDC00 + (c & 0x3FF))
    return re.sub("[\U00010000-\U0010FFFF]", esc, text)


# Accepted differences from expected/: each rule says exactly how a cell may differ, so anything
# else in that cell still fails.
RULES = {
    # the same JSON text once non-BMP characters are escaped the AWS way
    "non_bmp_escape": lambda e, a: a is not None and _escape_non_bmp(a) == e,
    # the same timestamp once microseconds are truncated to milliseconds, as AWS keeps them
    "ms_truncation": lambda e, a: a is not None and e is not None and a[:-3] + "000" == e,
}


def diff(name, expected, actual, known=None):
    """Print per-row, per-column differences; returns the number of unexpected ones.
    known: {(row_key, column): rule name in RULES}; such a cell passes only if it differs
    exactly as the rule allows."""
    known = known or {}
    bad = 0
    if len(expected) != len(actual):
        print(f"  {name}: {len(actual)} rows, expected {len(expected)}")
        bad += 1
    for i, (e, a) in enumerate(zip(expected, actual)):
        rk = e.get("id") or f"{e.get('source_object')}#{e.get('event_name') or e.get('span_name')}"
        # A column added to (or dropped from) columns.json must fail until expected/ is
        # regenerated, not go unchecked.
        if set(e) != set(a):
            print(f"  {name} row {i} [{rk}]: columns differ: missing {sorted(set(e) - set(a))}, "
                  f"extra {sorted(set(a) - set(e))}")
            bad += 1
        for k in e:
            if e.get(k) != a.get(k):
                rule = known.get((rk, k))
                if rule and RULES[rule](e.get(k), a.get(k)):
                    print(f"  {name} [{rk}] {k}: accepted ({rule})")
                    continue
                print(f"  {name} row {i} [{rk}] {k}:{f' not explained by {rule}' if rule else ''}\n"
                      f"    expected {e.get(k)!r}\n    actual   {a.get(k)!r}")
                bad += 1
    return bad
