#!/usr/bin/env bash
# Run one read-only SQL statement against the TraceForce lakehouse through Snowflake and print
# the result as CSV. Needs python3 with snowflake-connector-python installed.
#
#   snowflake_query.sh "SELECT count(*) FROM \"agent_events\""
#   snowflake_query.sh -f query.sql
#
# Authentication, by what the environment has:
#   - all five of SNOWFLAKE_ORGANIZATION_NAME, SNOWFLAKE_ACCOUNT_NAME, SNOWFLAKE_USER,
#     SNOWFLAKE_AUTHENTICATOR (= "SNOWFLAKE_JWT") and SNOWFLAKE_PRIVATE_KEY set: key-pair auth;
#   - none of them set: the connection the connector resolves on its own
#     ($SNOWFLAKE_DEFAULT_CONNECTION_NAME, else connections.toml's configured default; SSO,
#     password or encrypted-key auth all work).
# A partial set is an error, because the default connection could be another account. The
# Terraform provider reads the same names, so SNOWFLAKE_PRIVATE_KEY must hold the deploy user's
# key whenever terraform apply runs; keep the query user's credentials in a separate shell or in
# connections.toml (README "Grant query access").
#
# Names are fixed by the module (warehouse/database traceforce_lakehouse, schema traceforce,
# reader role traceforce_lakehouse_reader). Optional:
#   TRACEFORCE_LAKEHOUSE_MAX_ROWS           rows to print (default 200; 0 = all)
#   TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT  seconds before Snowflake cancels the query (default
#                                           300; 0 = 7 days, Snowflake's maximum, not unlimited)
#
# Output: CSV on stdout, "-- 0 rows" or a truncation note on stderr; exit 1 with Snowflake's
# failure reason on stderr when the query fails.
#
# Read-only model: every query runs as traceforce_lakehouse_reader with SECONDARY ROLES NONE, so
# a connecting user's broader roles do not leak through. The preamble and the query are
# submitted as one request with the exact statement count, so Snowflake's own parser rejects a
# smuggled extra statement. The forms that could re-enable a broader role inside one parsed
# statement are refused below: the ->> operator, a non-read first keyword (Scripting blocks,
# EXECUTE IMMEDIATE) and a bare PROCEDURE/CALL token (anonymous caller's-rights procedure). A
# query user that holds only the reader role is the other half of the guarantee.
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
# 604800 (7 days) is Snowflake's hard maximum for STATEMENT_TIMEOUT_IN_SECONDS. 10# forces base
# 10: bash would otherwise read a leading-zero value as octal, and "08"/"09" make (( )) fail,
# which the if treats as false -- silently skipping this check. The length cap keeps the
# arithmetic inside 64 bits, so an absurdly long digit string cannot wrap past the comparison.
if (( ${#STATEMENT_TIMEOUT} > 18 || 10#$STATEMENT_TIMEOUT > 604800 )); then
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

# The python steps read $SQL from a file; a large query passed as argv hits the OS argument-size
# limit.
SQL_FILE="$(mktemp)"
trap 'rm -f "$SQL_FILE"' EXIT
printf '%s' "$SQL" > "$SQL_FILE"

# ->> chains full statements (USE ROLE, DML) into one parsed statement. A plain substring check,
# so it cannot hide inside a quote or comment.
if [[ "$SQL" == *"->>"* ]]; then
  echo "refusing to run: the Snowflake pipe operator (->>) can chain a read into privileged statements as one Snowflake-parsed statement -- not allowed here (to search stored text for those characters, split the literal: LIKE '%-' || '>>%')" >&2
  exit 2
fi

command -v python3 >/dev/null 2>&1 || { echo "python3 is required (see the header)" >&2; exit 2; }

# Scan the bare tokens (outside string literals, quoted identifiers and comments): the first
# keyword must be a read, and no PROCEDURE or CALL token may appear anywhere. Control/Unicode
# line separators and non-UTF-8 input are refused so this scanner never has to agree with
# Snowflake's lexer about where a comment ends (a bare CR never reaches either side: both file
# reads are text-mode, which turns it into a newline). A column or JSON key named call/procedure
# has to be double-quoted.
SCAN="$(python3 -c '
import re, sys
try:
    sql = open(sys.argv[1], encoding="utf-8").read().lstrip("\ufeff")
except UnicodeDecodeError:
    print("|utf8")
    sys.exit(0)
if re.search("[\x0b\x0c\x1c\x1d\x1e\x85\u2028\u2029]", sql):
    print("|linesep")
    sys.exit(0)
i, n = 0, len(sql)
words = []
while i < n:
    c = sql[i]
    if c.isspace():
        i += 1
    elif sql.startswith("--", i) or sql.startswith("//", i):
        j = sql.find("\n", i)
        i = n if j == -1 else j + 1
    elif sql.startswith("/*", i):
        j = sql.find("*/", i + 2)
        i = n if j == -1 else j + 2
    elif sql.startswith("$$", i):
        j = sql.find("$$", i + 2)
        i = n if j == -1 else j + 2
    elif c == "\x27" or c == "\"":
        j = i + 1
        while j < n:
            if c == "\x27" and sql[j] == "\\":
                j += 2
            elif sql[j] == c:
                if j + 1 < n and sql[j + 1] == c:
                    j += 2
                else:
                    break
            else:
                j += 1
        i = j + 1
    elif c.isalnum() or c in "_$":
        j = i
        while j < n and (sql[j].isalnum() or sql[j] in "_$"):
            j += 1
        words.append(sql[i:j].upper())
        i = j
    else:
        i += 1
print((words[0] if words else "") + "|" + ("procedure" if "PROCEDURE" in words or "CALL" in words else ""))
' "$SQL_FILE")"
FIRST="${SCAN%%|*}"
ESCAPE="${SCAN#*|}"
case "$ESCAPE" in
  utf8) echo "refusing to run: the query text is not valid UTF-8" >&2; exit 2 ;;
  linesep) echo "refusing to run: the query contains a control or Unicode line-separator character (U+000B, U+000C, U+001C-U+001E, U+0085, U+2028 or U+2029); use plain newlines" >&2; exit 2 ;;
esac
case "$FIRST" in
  SELECT|WITH|SHOW|DESCRIBE|DESC|EXPLAIN) ;;
  *) echo "refusing to run a non-read statement (first keyword: ${FIRST:-none found})" >&2; exit 2 ;;
esac
if [[ "$ESCAPE" == "procedure" ]]; then
  echo "refusing to run: the statement contains a bare CALL or PROCEDURE token; an anonymous WITH ... AS PROCEDURE ... CALL block runs with the caller's full rights as one Snowflake-parsed statement, so neither keyword is allowed here (double-quote a column or JSON key named call/procedure)" >&2
  exit 2
fi

# Key-pair auth needs all five; none means connections.toml. A partial set is refused (see header).
MISSING=()
for v in SNOWFLAKE_ORGANIZATION_NAME SNOWFLAKE_ACCOUNT_NAME SNOWFLAKE_USER SNOWFLAKE_AUTHENTICATOR SNOWFLAKE_PRIVATE_KEY; do
  [[ -z "${!v:-}" ]] && MISSING+=("$v")
done
if [[ ${#MISSING[@]} -eq 0 ]]; then
  HAVE_ENV_CREDS=1
  # The connector forces key-pair auth whenever a private key is given, so any other value here
  # would be silently ignored; refuse it instead.
  if [[ "$(printf '%s' "$SNOWFLAKE_AUTHENTICATOR" | tr '[:lower:]' '[:upper:]')" != "SNOWFLAKE_JWT" ]]; then
    echo "SNOWFLAKE_AUTHENTICATOR must be SNOWFLAKE_JWT for key-pair auth (got: $SNOWFLAKE_AUTHENTICATOR); unset all five SNOWFLAKE_* variables to use connections.toml instead" >&2
    exit 2
  fi
elif [[ ${#MISSING[@]} -eq 5 ]]; then
  HAVE_ENV_CREDS=0
else
  echo "partial key-pair env var set -- missing: ${MISSING[*]}" >&2
  echo "set all five (listed in this script's header) or none to use connections.toml instead" >&2
  exit 2
fi

# TIMEZONE is pinned to UTC because the account default is America/Los_Angeles and
# CURRENT_TIMESTAMP()/CURRENT_DATE() resolve in the session zone; the ts columns are UTC.
# STATEMENT_TIMEOUT_IN_SECONDS is the runaway-cost guard: the shared warehouse's resource
# monitor is notify-only so it never suspends the ingest/export Tasks.
PREAMBLE="USE ROLE \"$READER_ROLE\"; USE SECONDARY ROLES NONE; USE WAREHOUSE \"$WAREHOUSE\"; USE DATABASE \"$DB\"; USE SCHEMA \"$SCHEMA\"; ALTER SESSION SET TIMEZONE = 'UTC'; ALTER SESSION SET STATEMENT_TIMEOUT_IN_SECONDS = $STATEMENT_TIMEOUT"

python3 -c 'import snowflake.connector' 2>/dev/null \
  || { echo "snowflake-connector-python is not installed: pip install snowflake-connector-python" >&2; exit 2; }

python3 - "$PREAMBLE" "$SQL_FILE" "$MAX_ROWS" "$HAVE_ENV_CREDS" <<'PY'
import csv
import os
import sys

import snowflake.connector
from cryptography.hazmat.primitives import serialization

preamble, sql_file, max_rows = sys.argv[1], sys.argv[2], int(sys.argv[3])
have_env_creds = sys.argv[4] == "1"
with open(sql_file, encoding="utf-8") as f:
    sql = f.read().lstrip("\ufeff")
# max_rows was validated as a non-negative integer in bash.
# The preamble is fixed text, so splitting on ";" counts its statements; $SQL's count is left to Snowflake.
num_statements = sum(1 for s in preamble.split(";") if s.strip()) + 1


def load_der_key() -> bytes:
    # The connector wants DER PKCS8 bytes; the env var (shared with the Terraform provider) holds PEM text.
    pem = os.environ["SNOWFLAKE_PRIVATE_KEY"].encode()
    try:
        key = serialization.load_pem_private_key(pem, password=None)
    except TypeError:
        # cryptography raises TypeError for an encrypted key when no password is given.
        print(
            "SNOWFLAKE_PRIVATE_KEY is an encrypted key; this script takes an unencrypted PEM in the environment."
            " For an encrypted key use a connections.toml connection (private_key_file + private_key_file_pwd).",
            file=sys.stderr,
        )
        sys.exit(2)
    except ValueError as e:
        print(f"invalid SNOWFLAKE_PRIVATE_KEY: {e}", file=sys.stderr)
        sys.exit(2)
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
        # No arguments: the connector resolves the default connections.toml connection itself.
        con = snowflake.connector.connect()
    cur = con.cursor()
    cur.execute(f"{preamble}; {sql}", num_statements=num_statements)

    # The cursor starts at the first statement's result; nextset() steps past the preamble's.
    for _ in range(num_statements - 1):
        cur.nextset()
    columns = [c[0] for c in cur.description]

    # fetchmany bounds the download (one extra row detects truncation); rowcount gives the true total.
    if max_rows == 0:
        rows = cur.fetchall()
        total = len(rows)
    else:
        rows = cur.fetchmany(max_rows + 1)
        total = cur.rowcount
except (snowflake.connector.errors.Error, ValueError, TypeError) as e:
    # errno 8 is the statement-count mismatch: Snowflake rejected the whole request, preamble included.
    # The base Error class covers connect()-time failures as well as query errors.
    if getattr(e, "errno", None) == 8:
        print(
            "refusing to run more than one statement -- run one query at a time",
            file=sys.stderr,
        )
        sys.exit(2)
    print(e, file=sys.stderr)
    sys.exit(1)

if not rows:
    print("-- 0 rows", file=sys.stderr)
    sys.exit(0)

# rowcount is None for result types that carry no total; the fetched rows are the total then.
if total is None:
    total = len(rows)
out_rows = rows if max_rows == 0 else rows[:max_rows]
# Slicing rows (not CSV lines) keeps the cutoff on a row boundary even with multi-line fields.
try:
    w = csv.writer(sys.stdout, lineterminator="\n")
    w.writerow(columns)
    w.writerows(out_rows)
    sys.stdout.flush()
except BrokenPipeError:
    # The reader (e.g. head) closed stdout: stop quietly instead of printing a traceback.
    os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
    sys.exit(0)
if max_rows != 0 and total > max_rows:
    print(
        f"-- showing {max_rows} of {total} rows; set TRACEFORCE_LAKEHOUSE_MAX_ROWS=0 for all",
        file=sys.stderr,
    )
PY
