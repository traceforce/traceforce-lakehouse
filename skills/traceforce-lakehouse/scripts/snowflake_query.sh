#!/usr/bin/env bash
# Run one read-only SQL statement against the TraceForce lakehouse through Snowflake and print
# the result as CSV. Needs python3 with the snowflake-connector-python package installed
# (`pip install snowflake-connector-python`).
#
# Two ways to authenticate:
#   1. All five key-pair env vars set: SNOWFLAKE_ORGANIZATION_NAME, SNOWFLAKE_ACCOUNT_NAME,
#      SNOWFLAKE_USER, SNOWFLAKE_AUTHENTICATOR (= "SNOWFLAKE_JWT"), SNOWFLAKE_PRIVATE_KEY --
#      unlike the Terraform module's own provider, which only reads SNOWFLAKE_PRIVATE_KEY from
#      the environment (the organization name, account name, and user are non-secret provider
#      arguments there, not env vars).
#   2. None of those five set: a named connection from connections.toml (SSO, password or
#      encrypted-key auth all work this way, none of which the env vars above can express) --
#      connect() with no arguments picks this up on its own: $SNOWFLAKE_DEFAULT_CONNECTION_NAME
#      if set, else config.toml's default_connection_name, else connections.toml's [default]
#      section. This script doesn't need to know which; the connector resolves it.
# Not a user-facing choice to make up front -- whichever of the two this environment actually
# has determines which path runs, with no separate flag. A partial set of the five env vars is
# always an error (see below), never a silent fall-through to connections.toml.
#
#   snowflake_query.sh "SELECT count(*) FROM \"agent_events\""
#   snowflake_query.sh -f query.sql
#
# Names are fixed by the module (warehouse/database traceforce_lakehouse, schema traceforce,
# reader role traceforce_lakehouse_reader -- terraform/azure/query_role.tf). Optional:
#   TRACEFORCE_LAKEHOUSE_MAX_ROWS          rows to print (default 200; 0 = all)
#   TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT seconds before Snowflake cancels the query (default
#                                          300; 0 means 7 days, Snowflake's own built-in maximum,
#                                          not unlimited) -- the runaway-cost guard for ad-hoc
#                                          queries, since the shared warehouse's own resource
#                                          monitor (terraform/azure/compute.tf) is notify-only
#                                          and never suspends it (that would also stop the
#                                          scheduled ingest/export Tasks sharing the warehouse).
#
# Output: CSV on stdout, "-- 0 rows" or a truncation note on stderr; exit 1 with Snowflake's
# failure reason on stderr when the query fails.
#
# Read-only is enforced by Snowflake itself, not just this script: every query runs as
# traceforce_lakehouse_reader with SECONDARY ROLES NONE, so even a connecting user who also
# holds a broader role (e.g. ACCOUNTADMIN, common for whoever deployed this module) is
# genuinely restricted to that role's own grants -- SELECT on the tables plus MONITOR on the
# Tasks, no write privilege anywhere -- rather than Snowflake's default SECONDARY ROLES ALL
# session behavior silently letting that user's other privileges leak through despite an
# explicit USE ROLE.
#
# The exactly-one-statement guarantee against a multi-statement escape (e.g.
# "SELECT 1; USE SECONDARY ROLES ALL; DELETE ...") comes from Snowflake's own SQL parser, not a
# scanner written here: the preamble and the caller's query are submitted together as ONE
# request with the real expected statement count, and Snowflake rejects the whole request --
# executing NONE of it, preamble included -- the moment the actual parsed count doesn't match,
# including a payload that hides an extra ";"-separated statement inside a "--" comment (a real
# bypass an earlier, hand-written quote-only scanner in this script missed).
set -euo pipefail

DB="traceforce_lakehouse"
SCHEMA="traceforce"
WAREHOUSE="traceforce_lakehouse"
READER_ROLE="traceforce_lakehouse_reader"
MAX_ROWS="${TRACEFORCE_LAKEHOUSE_MAX_ROWS:-200}"
if ! [[ "$MAX_ROWS" =~ ^[0-9]+$ ]]; then
  echo "invalid TRACEFORCE_LAKEHOUSE_MAX_ROWS: $MAX_ROWS -- must be a non-negative integer" >&2
  exit 2
fi
STATEMENT_TIMEOUT="${TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT:-300}"
if ! [[ "$STATEMENT_TIMEOUT" =~ ^[0-9]+$ ]]; then
  echo "invalid TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT: $STATEMENT_TIMEOUT -- must be a non-negative integer" >&2
  exit 2
fi
# 604800 (7 days) is Snowflake's own hard max for STATEMENT_TIMEOUT_IN_SECONDS -- confirmed live
# (ALTER SESSION SET STATEMENT_TIMEOUT_IN_SECONDS accepts exactly 0..604800, rejecting 604801 with
# "parameter value out of range"). Checked here so a bad value fails fast with a clear message
# instead of making the preamble's ALTER SESSION fail later, after the query was already built.
# 10# forces base-10: bash's arithmetic context otherwise reads a leading-zero value (e.g. "08")
# as octal, and "08"/"09" aren't even valid octal digits, so plain -gt would error ("value too
# great for base") -- an error state that bash's [[ ]] -- and the if guarding it -- just treats
# as the comparison being false, silently skipping this whole check instead of catching it.
if (( 10#$STATEMENT_TIMEOUT > 604800 )); then
  echo "invalid TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT: $STATEMENT_TIMEOUT -- must be <= 604800 (Snowflake's own max, 7 days)" >&2
  exit 2
fi

if [[ "${1:-}" == "-f" ]]; then
  if [[ -z "${2:-}" ]]; then
    echo "usage: $0 \"SQL\" | -f file.sql" >&2
    exit 2
  fi
  SQL="$(cat "$2")"
else
  SQL="${1:-}"
fi
if [[ -z "$SQL" ]]; then
  echo "usage: $0 \"SQL\" | -f file.sql" >&2
  exit 2
fi

# $SQL is also written to this temp file so the two python3 invocations below can read it from
# a path instead of receiving it as a literal argv string: a large $SQL passed directly as a
# command-line argument hits the OS's real execve() argument-size limit ("Argument list too
# long") well within what -f is meant to support (many UNION branches, a big literal list).
SQL_FILE="$(mktemp)"
trap 'rm -f "$SQL_FILE"' EXIT
printf '%s' "$SQL" > "$SQL_FILE"

# This IS part of the read-only guarantee, not just a convenience check: Snowflake's flow
# operator (->>) chains full statements -- including USE ROLE, USE SECONDARY ROLES, and DML --
# together as ONE statement from the parser's own point of view, reopening the exact
# privilege-escalation path the exactly-one-statement guarantee exists to close for a connecting
# identity that also holds a broader role. There is no legitimate use of this operator for this
# skill's own read-only queries, so it's rejected outright -- as a plain substring check,
# deliberately not quote/comment-aware, so "->>" hiding inside either can't slip past instead.
if [[ "$SQL" == *"->>"* ]]; then
  echo "refusing to run: the Snowflake pipe operator (->>) can chain a read into privileged statements as one Snowflake-parsed statement -- not allowed here" >&2
  exit 2
fi

# Fail-fast convenience, not the read-only guarantee -- see the note above. In python3 (already
# a hard dependency below), not awk/grep: a line-oriented tool handles a leading "--" comment
# fine but not a multi-line "/* ... */" block comment, which needs real character-level state
# tracking. This scanner skips leading whitespace and both comment styles (repeating, so several
# in a row are all skipped; an unterminated one fails safe by leaving FIRST empty, which the
# case block below turns into a refusal) before taking the leading identifier token, stopping at
# any non-alphanumeric/underscore character rather than just whitespace -- Snowflake accepts a
# keyword with no space before what follows (e.g. "SELECT* FROM t"), and stopping only at
# whitespace would swallow the trailing "*"/"/*" into FIRST, false-rejecting a valid query.
FIRST="$(python3 -c '
import sys
sql = open(sys.argv[1]).read()
i, n = 0, len(sql)
while i < n:
    c = sql[i]
    if c.isspace():
        i += 1
    elif c == "-" and i + 1 < n and sql[i + 1] == "-":
        j = sql.find("\n", i)
        i = n if j == -1 else j + 1
    elif c == "/" and i + 1 < n and sql[i + 1] == "*":
        j = sql.find("*/", i + 2)
        i = n if j == -1 else j + 2
    else:
        break
j = i
while j < n and (sql[j].isalnum() or sql[j] == "_"):
    j += 1
print(sql[i:j].upper())
' "$SQL_FILE")"
case "$FIRST" in
  SELECT|WITH|SHOW|DESCRIBE|DESC|EXPLAIN) ;;
  *) echo "refusing to run a non-read statement (first keyword: $FIRST)" >&2; exit 2 ;;
esac

# Env-var key-pair auth only if ALL five are set; connections.toml only if NONE are set. A
# partial set is always an error, never a silent fall-through to connections.toml: that fallback
# would resolve to whatever default named connection happens to exist, which can easily be a
# different Snowflake account than the one these env vars are trying to reach (e.g. a typo'd or
# forgotten SNOWFLAKE_AUTHENTICATOR in an otherwise-complete key-pair setup). If that other
# account happens to also have a same-named reader role/database, the query would silently
# succeed against the wrong account with plausible-looking but wrong data -- worse than erroring.
MISSING=()
for v in SNOWFLAKE_ORGANIZATION_NAME SNOWFLAKE_ACCOUNT_NAME SNOWFLAKE_USER SNOWFLAKE_AUTHENTICATOR SNOWFLAKE_PRIVATE_KEY; do
  [[ -z "${!v:-}" ]] && MISSING+=("$v")
done
if [[ ${#MISSING[@]} -eq 0 ]]; then
  HAVE_ENV_CREDS=1
elif [[ ${#MISSING[@]} -eq 5 ]]; then
  HAVE_ENV_CREDS=0
else
  echo "partial key-pair env var set -- missing: ${MISSING[*]}" >&2
  echo "set all five (see README.md 'Before you start') or none to use connections.toml instead" >&2
  exit 2
fi

# USE ROLE/SECONDARY ROLES/WAREHOUSE/DATABASE/SCHEMA are real statements prepended ahead of the
# caller's query and submitted together with it as one multi-statement request below, not
# connection-time parameters -- a plain connection-level role/warehouse/database/schema setting
# isn't how this context gets applied, a real SQL USE statement in the same request is.
# Submitting them together with $SQL, under one real statement count, is also what makes
# Snowflake's own parser the enforcement point for both: it rejects the whole request --
# preamble included -- if $SQL smuggles in any extra statement.
# TIMEZONE is set to UTC here, not left at the session default (America/Los_Angeles): this
# module's own ts/upload_ts/ingested_at columns are all UTC, but CURRENT_TIMESTAMP()/
# CURRENT_DATE() resolve in the session time zone, so a query like
# "ts > DATEADD('hour', -1, CURRENT_TIMESTAMP())" would otherwise silently return the last 8-9
# hours (depending on DST), and CURRENT_DATE() would roll over at Pacific midnight instead of
# UTC midnight -- no error, just a wrong answer with no reason to suspect one.
#
# STATEMENT_TIMEOUT_IN_SECONDS caps a runaway query here specifically, not on the shared
# warehouse (terraform/azure/compute.tf's resource monitor is notify-only on purpose, so it
# never stops the scheduled ingest/export Tasks that also share it). 0 means 7 days here,
# Snowflake's own built-in maximum, not unlimited like TRACEFORCE_LAKEHOUSE_MAX_ROWS=0.
PREAMBLE="USE ROLE \"$READER_ROLE\"; USE SECONDARY ROLES NONE; USE WAREHOUSE \"$WAREHOUSE\"; USE DATABASE \"$DB\"; USE SCHEMA \"$SCHEMA\"; ALTER SESSION SET TIMEZONE = 'UTC'; ALTER SESSION SET STATEMENT_TIMEOUT_IN_SECONDS = $STATEMENT_TIMEOUT"

python3 - "$PREAMBLE" "$SQL_FILE" "$MAX_ROWS" "$HAVE_ENV_CREDS" <<'PY'
import csv
import os
import sys

import snowflake.connector
from cryptography.hazmat.primitives import serialization

preamble, sql_file, max_rows = sys.argv[1], sys.argv[2], int(sys.argv[3])
have_env_creds = sys.argv[4] == "1"
with open(sql_file) as f:
    sql = f.read()
# TRACEFORCE_LAKEHOUSE_MAX_ROWS is already validated as a non-negative integer in bash before
# this script runs, so int() here can't raise and max_rows can't be negative (which would
# otherwise slice from the end, e.g. rows[:-1], instead of erroring).
# The preamble is fixed by this script, never user input, so a plain split on ";" to count its
# own statements is safe here -- it's exactly the kind of naive count that would NOT be safe for
# $SQL, which is why $SQL's count is left to Snowflake's real parser instead (see below).
num_statements = sum(1 for s in preamble.split(";") if s.strip()) + 1


def load_der_key() -> bytes:
    # snowflake-connector-python's private_key parameter wants DER-encoded PKCS8 bytes, but the
    # module's own env var (matching the Terraform provider) holds raw PEM text.
    pem = os.environ["SNOWFLAKE_PRIVATE_KEY"].encode()
    key = serialization.load_pem_private_key(pem, password=None)
    return key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


try:
    if have_env_creds:
        con = snowflake.connector.connect(
            account=f"{os.environ['SNOWFLAKE_ORGANIZATION_NAME']}-{os.environ['SNOWFLAKE_ACCOUNT_NAME']}",
            user=os.environ["SNOWFLAKE_USER"],
            private_key=load_der_key(),
            authenticator=os.environ["SNOWFLAKE_AUTHENTICATOR"],
        )
    else:
        # No arguments: the connector resolves a named connection from connections.toml itself
        # (SNOWFLAKE_DEFAULT_CONNECTION_NAME, config.toml's default_connection_name, or
        # connections.toml's own [default] section, in that order) -- SSO, password or
        # encrypted-key auth all work here, none of which the env-var path above can express.
        con = snowflake.connector.connect()
    cur = con.cursor()
    cur.execute(f"{preamble}; {sql}", num_statements=num_statements)

    # A multi-statement execute() leaves the cursor positioned at the FIRST statement's result
    # set, not the last, so the preamble's own results (each just a "Statement executed
    # successfully" status row) have to be stepped past with nextset() to reach the caller's
    # actual query at the end. Kept inside this same try: a connector/transport error surfacing
    # here should get the same clean one-line handling as an error from execute() itself, not an
    # uncaught traceback.
    for _ in range(num_statements - 1):
        cur.nextset()
    columns = [c[0] for c in cur.description]

    # Unbounded except for the explicit MAX_ROWS=0 case: fetchall() always downloads the whole
    # result before anything is sliced, regardless of max_rows, so a small max_rows bounded
    # nothing there. fetchmany(max_rows + 1) fetches only enough to render the limit plus one
    # extra row to detect that more exist; cur.rowcount separately reports the query's true
    # total row count from Snowflake's own result metadata, not derived by counting rows.
    if max_rows == 0:
        rows = cur.fetchall()
        total = len(rows)
    else:
        rows = cur.fetchmany(max_rows + 1)
        total = cur.rowcount
except (snowflake.connector.errors.Error, ValueError, TypeError) as e:
    # errno 8 is "Actual statement count N did not match the desired statement count M" --
    # Snowflake rejects the whole request (preamble included, nothing executed) the moment $SQL
    # smuggles in an extra statement, including one hiding behind a quote inside a "--" comment.
    # Any other error -- a bad credential, a real syntax error in the caller's own query -- is
    # surfaced as-is. Catching the connector's own base Error class (not just ProgrammingError)
    # also covers a connect()-time failure, e.g. a bad account name raising DatabaseError
    # instead, which ProgrammingError alone wouldn't catch, leaking a full Python traceback
    # (local file paths included). ValueError/TypeError are caught for the same reason, in the
    # env-creds path only: load_der_key() raises ValueError for malformed PEM text and TypeError
    # for an encrypted key used with no password -- neither is a snowflake.connector error.
    if getattr(e, "errno", None) == 8:
        print(
            "refusing to run more than one statement -- run one query at a time",
            file=sys.stderr,
        )
        sys.exit(2)
    prefix = ""
    if have_env_creds and isinstance(e, (ValueError, TypeError)):
        prefix = "invalid SNOWFLAKE_PRIVATE_KEY: "
    print(f"{prefix}{e}", file=sys.stderr)
    sys.exit(1)

if not rows:
    print("-- 0 rows", file=sys.stderr)
    sys.exit(0)

out_rows = rows if max_rows == 0 else rows[:max_rows]
# Truncating this list and handing it straight to csv.writer means the cutoff always lands on a
# real row boundary -- there's no re-parsing of CSV text (and so no way for a multi-line quoted
# field, e.g. content_input/tool_args, to get split mid-value the way a line-count-based cutoff
# could).
w = csv.writer(sys.stdout, lineterminator="\n")
w.writerow(columns)
w.writerows(out_rows)
if max_rows != 0 and total > max_rows:
    print(
        f"-- showing {max_rows} of {total} rows; set TRACEFORCE_LAKEHOUSE_MAX_ROWS=0 for all",
        file=sys.stderr,
    )
PY
