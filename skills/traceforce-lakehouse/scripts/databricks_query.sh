#!/usr/bin/env bash
# Run one read-only SQL statement against the TraceForce lakehouse on Azure Databricks and print
# the result as CSV, or (--runs) print the ingest and mirror jobs' recent runs. Needs python3 and,
# for a person's login, the Azure CLI. No other packages.
#
#   databricks_query.sh "SELECT count(*) FROM agent_events"
#   databricks_query.sh -f query.sql
#   databricks_query.sh --runs [N]      the last N runs of each job (default 5), failed tasks' errors
#
# Configuration (the module's outputs):
#   DATABRICKS_HOST                     databricks_workspace_url (adb-<id>.<n>.azuredatabricks.net)
#   TRACEFORCE_LAKEHOUSE_WAREHOUSE_ID   query_warehouse_id (not needed for --runs)
#
# Authentication, by what the environment has:
#   - DATABRICKS_CLIENT_ID and DATABRICKS_CLIENT_SECRET both set: that service principal (OAuth
#     machine-to-machine, with a Databricks OAuth secret generated in Databricks for the
#     principal; a Microsoft Entra client secret is refused), e.g. a team's read-only principal
#     listed in the module's reader_service_principal_names;
#   - neither set: the person signed in to the Azure CLI (az login), or else to the Databricks CLI
#     for this workspace (databricks auth login --host <workspace URL>).
# The Databricks Terraform provider reads the same names (and DATABRICKS_HOST): a shell holding a
# deploy service principal's DATABRICKS_CLIENT_ID/SECRET would query as that principal. Keep the
# query identity's credentials in a separate shell from the one that runs terraform apply.
# Never paste a token or secret into a chat; put it in the environment the agent is started from.
#
# Optional:
#   TRACEFORCE_LAKEHOUSE_MAX_ROWS           rows to print (default 200; 0 = all, up to Databricks'
#                                           25 MiB result limit)
#   TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT  seconds before the script cancels the query (default
#                                           300; 0 = no limit from the script)
#
# Output: CSV on stdout, "-- 0 rows" or a truncation note on stderr; exit 1 with Databricks'
# error on stderr when the query fails, exit 2 for a refused query or a configuration error.
# Ctrl-C or a tool timeout cancels the running statement instead of leaving it running (exit 130).
#
# Read-only model: the identity decides what a statement could change. A principal listed in the
# module's reader inputs holds only SELECT on the lakehouse schema; a workspace admin or the
# identity that deployed the module holds much more, so query as a reader (best: a team's own
# read-only service principal). The script also runs only a single read statement (first keyword
# SELECT, WITH, SHOW, DESCRIBE, DESC or EXPLAIN; nothing after a ;) and refuses write keywords
# anywhere outside strings, quoted identifiers and comments, so a scripting block (BEGIN ... END),
# EXECUTE IMMEDIATE, CALL or a write behind a WITH is never sent. A column or JSON key named like
# one of those keywords has to be backtick-quoted.
set -euo pipefail

CATALOG="traceforce_lakehouse"
SCHEMA="traceforce"
MAX_ROWS="${TRACEFORCE_LAKEHOUSE_MAX_ROWS:-200}"
if ! [[ "$MAX_ROWS" =~ ^[0-9]{1,9}$ ]]; then
  echo "invalid TRACEFORCE_LAKEHOUSE_MAX_ROWS: $MAX_ROWS -- must be a non-negative integer" >&2
  exit 2
fi
STATEMENT_TIMEOUT="${TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT:-300}"
if ! [[ "$STATEMENT_TIMEOUT" =~ ^[0-9]{1,9}$ ]]; then
  echo "invalid TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT: $STATEMENT_TIMEOUT -- must be a non-negative integer" >&2
  exit 2
fi

usage() { echo "usage: $0 \"SQL\" | -f file.sql | --runs [N]" >&2; exit 2; }

MODE="sql"
case "${1:-}" in
  --runs)
    MODE="runs"
    RUNS="${2:-5}"
    [[ "$RUNS" =~ ^[1-9][0-9]{0,2}$ ]] || { echo "invalid --runs count: $RUNS -- 1 to 999" >&2; exit 2; }
    ;;
  -f)
    [[ -n "${2:-}" ]] || usage
    SQL="$(cat "$2")"
    ;;
  *)
    SQL="${1:-}"
    ;;
esac

command -v python3 >/dev/null 2>&1 || { echo "python3 is required (see the header)" >&2; exit 2; }

if [[ -z "${DATABRICKS_HOST:-}" ]]; then
  echo "DATABRICKS_HOST is not set: set it to the module's databricks_workspace_url output (adb-<id>.<n>.azuredatabricks.net)" >&2
  exit 2
fi
if [[ -n "${DATABRICKS_CLIENT_ID:-}" && -z "${DATABRICKS_CLIENT_SECRET:-}" ]] || [[ -z "${DATABRICKS_CLIENT_ID:-}" && -n "${DATABRICKS_CLIENT_SECRET:-}" ]]; then
  echo "set both DATABRICKS_CLIENT_ID and DATABRICKS_CLIENT_SECRET (a service principal), or neither (your az login)" >&2
  exit 2
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ "$MODE" == "sql" ]]; then
  [[ -n "$SQL" ]] || usage
  if [[ -z "${TRACEFORCE_LAKEHOUSE_WAREHOUSE_ID:-}" ]]; then
    echo "TRACEFORCE_LAKEHOUSE_WAREHOUSE_ID is not set: set it to the module's query_warehouse_id output" >&2
    exit 2
  fi
  # The python steps read the query from a file: a large query as argv hits the OS size limit.
  printf '%s' "$SQL" > "$TMP_DIR/query.sql"

  # Scan the bare tokens (outside string literals, raw strings, quoted identifiers and nested
  # comments, as Databricks SQL lexes them): the first keyword must be a read, no write keyword
  # may appear anywhere, nothing but comments may follow a ;, and no /*+ hint (Databricks reads
  # strings inside one, unlike a comment). A -- comment ends at a newline
  # without a backslash before it, as in Databricks. Control/Unicode line separators and non-UTF-8
  # input are refused, so no other character can end a comment for Databricks but not here.
  cat > "$TMP_DIR/scan.py" <<'PY'
import re, sys
WRITES = {"INSERT", "UPDATE", "DELETE", "MERGE", "CREATE", "DROP", "ALTER", "TRUNCATE", "GRANT",
          "REVOKE", "COPY", "CALL", "EXECUTE", "OVERWRITE", "REFRESH", "OPTIMIZE", "VACUUM"}
try:
    sql = open(sys.argv[1], encoding="utf-8").read().lstrip("﻿")
except UnicodeDecodeError:
    print("|utf8"); sys.exit(0)
if re.search("[\x0b\x0c\x1c\x1d\x1e\x85  ]", sql):
    print("|linesep"); sys.exit(0)
i, n, words, ended, more, hint = 0, len(sql), [], False, False, False
while i < n:
    c = sql[i]
    if c.isspace():
        i += 1
        continue
    if sql.startswith("--", i):           # backslash-newline continues it, as in Databricks
        j = i + 2
        while j < n and sql[j] != "\n":
            j += 2 if sql.startswith("\\\n", j) else 1
        i = j + 1
        continue
    if ended and not sql.startswith("/*", i):   # only comments may follow a ;
        more = True
    if c == ";":
        ended = True
        i += 1
    elif sql.startswith("/*+", i):         # a hint, lexed as code (strings and all), not a comment
        hint = True
        break
    elif sql.startswith("/*", i):          # nested, as Databricks SQL allows
        depth, j = 1, i + 2
        while j < n and depth:
            if sql.startswith("/*", j): depth += 1; j += 2
            elif sql.startswith("*/", j): depth -= 1; j += 2
            else: j += 1
        i = j
    elif c in "rR" and i + 1 < n and sql[i + 1] in "'\"":   # raw string: no escapes
        q = sql[i + 1]
        j = sql.find(q, i + 2)
        i = n if j == -1 else j + 1
    elif c in "'\"":
        j = i + 1
        while j < n and sql[j] != c:
            j += 2 if sql[j] == "\\" else 1
        i = j + 1
    elif c == "`":
        j = i + 1
        while j < n:
            if sql[j] == "`":
                if j + 1 < n and sql[j + 1] == "`": j += 2; continue
                break
            j += 1
        i = j + 1
    elif c.isalnum() or c == "_":
        j = i
        while j < n and (sql[j].isalnum() or sql[j] == "_"):
            j += 1
        words.append(sql[i:j].upper())
        i = j
    else:
        i += 1
if hint:
    print("|hint"); sys.exit(0)
if more:
    print("|multi"); sys.exit(0)
bad = sorted(set(words) & WRITES)
print((words[0] if words else "") + "|" + ",".join(bad))
PY
  SCAN="$(python3 -I "$TMP_DIR/scan.py" "$TMP_DIR/query.sql")"
  FIRST="${SCAN%%|*}"
  FLAG="${SCAN#*|}"
  case "$FLAG" in
    utf8) echo "refusing to run: the query text is not valid UTF-8" >&2; exit 2 ;;
    hint) echo "refusing to run: optimizer hints (/*+ ... */) aren't allowed; remove the hint" >&2; exit 2 ;;
    multi) echo "refusing to run: text after a ; (one statement at a time; a ; is allowed only at the end)" >&2; exit 2 ;;
    linesep) echo "refusing to run: the query contains a control or Unicode line-separator character (U+000B, U+000C, U+001C-U+001E, U+0085, U+2028 or U+2029); use plain newlines" >&2; exit 2 ;;
  esac
  case "$FIRST" in
    SELECT|WITH|SHOW|DESCRIBE|DESC|EXPLAIN) ;;
    *) echo "refusing to run a non-read statement (first keyword: ${FIRST:-none found})" >&2; exit 2 ;;
  esac
  if [[ -n "$FLAG" ]]; then
    echo "refusing to run: the statement contains $FLAG, which can change data or run other statements (backtick-quote a column or JSON key with that name)" >&2
    exit 2
  fi
fi

# In the background so Ctrl-C or a tool timeout's TERM reaches Python, which cancels the running
# statement instead of leaving it running on the warehouse (as athena_query.sh does).
python3 -I - "$MODE" "$TMP_DIR" "$MAX_ROWS" "$STATEMENT_TIMEOUT" "${RUNS:-5}" "$CATALOG" "$SCHEMA" <<'PY' &
import base64, concurrent.futures, csv, datetime, json, os, signal, socket, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

mode, tmp, max_rows, timeout, runs, catalog, schema = sys.argv[1:8]
max_rows, timeout, runs = int(max_rows), int(timeout), int(runs)
host = os.environ["DATABRICKS_HOST"].strip().split("://", 1)[-1]   # any scheme, in any case
host = host.split("/")[0].split("?")[0].split("#")[0]   # a browser address can carry a path or ?o=<id>
base = f"https://{host}"
m2m = bool(os.environ.get("DATABRICKS_CLIENT_ID"))
AZURE_DATABRICKS = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"  # the Azure Databricks resource (Entra app ID)
READER_HINT = ("the identity needs to be listed in the lakehouse module's reader inputs "
               "(reader_user_names, reader_group_names or reader_service_principal_names) "
               "and have the workspace entitlement Databricks SQL access")
# Readers see the jobs only when the module sets reader_can_view_jobs = true (off by default).
RUNS_HINT = ("run history needs the lakehouse module's reader_can_view_jobs = true (ask whoever deploys "
             "it); without it, SELECT * FROM freshness shows whether data is arriving")


def fail(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


def auth_failed():
    if m2m:
        fail("authentication failed: check DATABRICKS_CLIENT_ID and DATABRICKS_CLIENT_SECRET "
             "(the service principal's application ID and a Databricks OAuth secret generated for "
             "it in Databricks, not a Microsoft Entra client secret)", 2)
    fail("authentication failed: run `az login` (in the tenant of the Databricks workspace) or "
         f"`databricks auth login --host {base}`, then retry", 2)


def cli_token():
    """The Databricks CLI's login for this workspace (`databricks auth login`), or None."""
    try:
        p = subprocess.run(["databricks", "auth", "token", "--host", base, "-o", "json"],
                           capture_output=True, text=True, timeout=120)
        return json.loads(p.stdout)["access_token"] if p.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError, TypeError):
        return None


def token():
    if m2m:
        req = urllib.request.Request(
            f"{base}/oidc/v1/token",
            data=urllib.parse.urlencode({"grant_type": "client_credentials", "scope": "all-apis"}).encode(),
            headers={"Authorization": "Basic " + base64.b64encode(
                f"{os.environ['DATABRICKS_CLIENT_ID']}:{os.environ['DATABRICKS_CLIENT_SECRET']}".encode()).decode()})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)["access_token"]
        except urllib.error.HTTPError as e:
            if e.code in (400, 401, 403):
                auth_failed()
            fail(f"OAuth token request failed: HTTP {e.code}")
        except urllib.error.URLError as e:
            fail(f"cannot reach {host}: {e.reason} (check DATABRICKS_HOST)", 2)
        except OSError as e:   # a read timeout
            fail(f"cannot reach {host}: {e} (check DATABRICKS_HOST)", 2)
        except (ValueError, KeyError):   # a proxy or login page, not the token endpoint
            fail(f"unexpected reply from {host} to the token request (check DATABRICKS_HOST)", 2)
    # A person: the Azure CLI first, then a Databricks CLI login for this workspace.
    az = True
    try:
        p = subprocess.run(["az", "account", "get-access-token", "--resource", AZURE_DATABRICKS,
                            "--query", "accessToken", "-o", "tsv"], capture_output=True, text=True, timeout=120)
        if p.returncode == 0 and p.stdout.strip():
            return p.stdout.strip()
    except FileNotFoundError:
        az = False
    except subprocess.TimeoutExpired:
        pass
    t = cli_token()
    if t:
        return t
    if not az:
        fail("no sign-in found: the Azure CLI (az) is not installed and there is no Databricks CLI "
             f"login for this workspace. Run `az login`, or `databricks auth login --host {base}`, "
             "or set DATABRICKS_CLIENT_ID and DATABRICKS_CLIENT_SECRET for a service principal", 2)
    auth_failed()


TOKEN = token()


def renew_token():
    """After a 401: a new token (an az login token can expire during a long run). Exits like token()."""
    global TOKEN
    TOKEN = token()


# Throttling and temporary server failures; a request is retried on these, and on a network error
# or timeout, only when it's safe to repeat (the GETs; never the statement submission).
TRANSIENT_HTTP = {429, 500, 502, 503, 504}
GET_RETRIES = 4   # waits 1, 2, 4, 8 s


def api(method, path, body=None, retries=0):
    attempt, renewed = 0, False
    while True:
        req = urllib.request.Request(base + path, method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                raw = r.read()
            try:
                return json.loads(raw) if raw else {}
            except ValueError:   # a proxy or login page; failing here still cancels a running statement
                fail(f"unexpected reply from {host}, not JSON (check DATABRICKS_HOST)", 2)
        except urllib.error.HTTPError as e:
            if e.code == 401 and not renewed:   # refused before anything ran, so safe to repeat
                renew_token()
                renewed = True
                continue
            if e.code in TRANSIENT_HTTP and attempt < retries:
                time.sleep(2 ** attempt)
                attempt += 1
                continue
            api_error(e, path)
        except OSError as e:   # URLError, a timeout, a dropped connection
            if attempt < retries:
                time.sleep(2 ** attempt)
                attempt += 1
                continue
            # A read timeout (a connect timeout comes wrapped in URLError): the submission was sent,
            # so the statement may be running, with no id to cancel it by.
            if path == "/api/2.0/sql/statements" and isinstance(e, socket.timeout):
                fail(f"no reply from {host} to the query request within 120 s; the query may be running "
                     "on the warehouse (see Query History); retry once it ends")
            fail(f"cannot reach {host}: {getattr(e, 'reason', e)} (check DATABRICKS_HOST)", 2)


def api_error(e, path):
    try:
        err = json.loads(e.read())
    except ValueError:
        err = {}
    msg = err.get("message") or err.get("error") or f"HTTP {e.code}"
    if e.code == 401:
        auth_failed()
    if e.code == 403 or err.get("error_code") == "PERMISSION_DENIED":
        fail(f"permission denied: {msg} -- {RUNS_HINT if mode == 'runs' else READER_HINT}")
    if e.code == 404 and path.startswith("/api/2.0/sql/statements") and "warehouse" in msg.lower():
        fail(f"{msg} -- check TRACEFORCE_LAKEHOUSE_WAREHOUSE_ID (the module's query_warehouse_id output)", 2)
    fail(f"{msg} (HTTP {e.code})")


def cancel_quietly(sid):
    """Best-effort cancel of a running statement; True if Databricks accepted it."""
    renewed = False
    for attempt in range(3):
        req = urllib.request.Request(f"{base}/api/2.0/sql/statements/{sid}/cancel", method="POST",
                                     headers={"Authorization": f"Bearer {TOKEN}"})
        try:
            with urllib.request.urlopen(req, timeout=30):
                return True
        except urllib.error.HTTPError as e:
            if e.code == 401 and not renewed:
                try:
                    renew_token()
                except SystemExit:   # keep the caller's exit code and its "could not be cancelled"
                    return False
                renewed = True
                continue
            if e.code not in TRANSIENT_HTTP:
                return False
        except OSError:
            pass
        time.sleep(2 ** attempt)
    return False


def write_csv(header, rows):
    try:
        w = csv.writer(sys.stdout, lineterminator="\n")
        w.writerow(header)
        w.writerows(rows)
        sys.stdout.flush()
    except BrokenPipeError:
        # The reader (e.g. head) closed stdout: stop quietly instead of printing a traceback.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        sys.exit(0)


def utc(ms):
    return datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S") if ms else ""


if mode == "runs":
    # Each row is printed as soon as it's built, so a tool timeout (TERM kills this mode; no
    # statement to cancel) still leaves the runs finished so far.
    w, printed = csv.writer(sys.stdout, lineterminator="\n"), 0
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=8)   # a failed run's tasks' errors
    for name in ("traceforce-lakehouse-ingest", "traceforce-lakehouse-mirror"):
        jobs = api("GET", "/api/2.2/jobs/list?" + urllib.parse.urlencode({"name": name}), retries=GET_RETRIES).get("jobs", [])
        if not jobs:
            fail(f"job {name} not found, or this identity can't view it -- {RUNS_HINT}")
        job_id = jobs[0]["job_id"]
        # Always by job ID: whether a list without one is limited to viewable jobs is untested.
        # The API returns at most 25 runs per request: follow next_page_token until `runs` are
        # collected, a page comes back empty or there's no next page.
        listed, page_token = [], None
        while len(listed) < runs:
            q = {"job_id": job_id, "limit": min(runs - len(listed), 25)}
            if page_token:
                q["page_token"] = page_token
            page = api("GET", "/api/2.2/jobs/runs/list?" + urllib.parse.urlencode(q), retries=GET_RETRIES)
            listed += page.get("runs", [])
            page_token = page.get("next_page_token")
            if not page.get("runs") or not page_token:
                break
        for r in listed[:runs]:
            st = r.get("state", {})
            errors = []
            if st.get("result_state") not in (None, "SUCCESS"):
                detail = api("GET", f"/api/2.2/jobs/runs/get?run_id={r['run_id']}", retries=GET_RETRIES)
                failed = [t for t in detail.get("tasks", [])
                          if t.get("state", {}).get("result_state") not in (None, "SUCCESS")]
                outputs = pool.map(lambda t: api("GET", f"/api/2.2/jobs/runs/get-output?run_id={t['run_id']}",
                                                 retries=GET_RETRIES), failed)
                for t, o in zip(failed, outputs):   # in task order
                    errors.append(f"{t['task_key']}: {o.get('error') or t['state'].get('state_message', '')}".strip())
            end = r.get("end_time") or 0
            row = [name, r["run_id"], utc(r.get("start_time")),
                   round((end - r["start_time"]) / 1000) if end and r.get("start_time") else "",
                   st.get("result_state") or st.get("life_cycle_state", ""), r.get("trigger", ""),
                   st.get("state_message", ""), " | ".join(errors)]
            try:
                if not printed:
                    w.writerow(["job", "run_id", "started_utc", "duration_s", "result", "trigger", "message",
                                "failed_tasks"])
                w.writerow(row)
                sys.stdout.flush()
            except BrokenPipeError:   # the reader (e.g. head) closed stdout: stop quietly
                os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
                os._exit(0)
            printed += 1
    if not printed:
        print("-- 0 rows", file=sys.stderr)
    sys.exit(0)

# --- one SQL statement through the Statement Execution API -------------------------------------
def interrupted(*_):
    raise KeyboardInterrupt
signal.signal(signal.SIGTERM, interrupted)
with open(os.path.join(tmp, "query.sql"), encoding="utf-8") as f:
    sql = f.read().lstrip("﻿")
body = {
    "warehouse_id": os.environ["TRACEFORCE_LAKEHOUSE_WAREHOUSE_ID"],
    "statement": sql,
    "catalog": catalog,          # unqualified names resolve in traceforce_lakehouse.traceforce
    "schema": schema,
    "disposition": "INLINE",
    "format": "JSON_ARRAY",
    "wait_timeout": "0s",        # return the statement id at once, so an interrupt can cancel it
}
if max_rows:
    body["row_limit"] = max_rows + 1   # one extra row tells whether there are more
start = time.monotonic()
sid, cancel_tried = None, False
try:
    r = api("POST", "/api/2.0/sql/statements", body)
    sid = r.get("statement_id")
    while r.get("status", {}).get("state") in ("PENDING", "RUNNING"):
        if timeout and time.monotonic() - start > timeout:
            cancel_tried = True
            if cancel_quietly(sid):
                fail(f"cancelled after {timeout} s (TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT); narrow the query or raise the limit")
            fail(f"timed out after {timeout} s (TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT); statement {sid} could not be cancelled; it may still be running")
        time.sleep(1)
        r = api("GET", f"/api/2.0/sql/statements/{sid}", retries=GET_RETRIES)
except SystemExit:
    # A status check failed for good (not transient, or still failing after the retries): don't
    # leave the statement running on the warehouse, unless the timeout above already tried (a
    # check can fail after the deadline without the timeout having run).
    if sid and not cancel_tried:
        print(f"-- statement {sid} cancelled" if cancel_quietly(sid)
              else f"-- statement {sid} could not be cancelled; it may still be running", file=sys.stderr)
    raise
except KeyboardInterrupt:
    signal.signal(signal.SIGINT, signal.SIG_IGN)   # finish the cancel even if signalled again
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if sid:
        fail(f"interrupted; statement {sid} cancelled" if cancel_quietly(sid)
             else f"interrupted; statement {sid} could not be cancelled; it may still be running", 130)
    fail("interrupted before Databricks returned a statement id; it may still run until it ends", 130)
status = r.get("status", {})
if status.get("state") != "SUCCEEDED":
    err = status.get("error", {})
    msg = err.get("message") or status.get("state", "unknown state")
    if err.get("error_code") == "PERMISSION_DENIED" or "PERMISSION_DENIED" in msg or "INSUFFICIENT_PERMISSIONS" in msg:
        msg += f" -- {READER_HINT}"
    elif "Inline byte limit exceeded" in msg:   # error_code is only BAD_REQUEST
        msg += (" -- the result is over Databricks' 25 MiB limit for this script; narrow the query "
                "(fewer columns or rows, or aggregate) or lower TRACEFORCE_LAKEHOUSE_MAX_ROWS")
    fail(msg)

manifest = r.get("manifest", {})
columns = [c["name"] for c in manifest.get("schema", {}).get("columns", [])]
result = r.get("result") or {}
rows = result.get("data_array") or []
link = result.get("next_chunk_internal_link")
while link and (not max_rows or len(rows) <= max_rows):
    chunk = api("GET", link, retries=GET_RETRIES)
    rows += chunk.get("data_array") or []
    link = chunk.get("next_chunk_internal_link")

if not rows:
    print("-- 0 rows", file=sys.stderr)
    sys.exit(0)
more = (max_rows and len(rows) > max_rows)
write_csv(columns, rows[:max_rows] if max_rows else rows)
if more:
    print(f"-- showing {max_rows} rows; more exist; set TRACEFORCE_LAKEHOUSE_MAX_ROWS=0 for all", file=sys.stderr)
PY
PY_PID=$!
# A background job doesn't get Ctrl-C (bash ignores SIGINT for it), so both signals are passed on
# as TERM. wait returns early when a trap runs; keep waiting for Python's own exit status.
trap 'kill -TERM "$PY_PID" 2>/dev/null || true' INT TERM
set +e
wait "$PY_PID"; RC=$?
while kill -0 "$PY_PID" 2>/dev/null; do wait "$PY_PID"; RC=$?; done
exit "$RC"
