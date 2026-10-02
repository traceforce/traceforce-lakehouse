#!/usr/bin/env python3
# Run one read-only SQL statement against the TraceForce lakehouse through Snowflake and print
# the result as CSV. This is the implementation behind snowflake_query.sh (macOS/Linux) and
# snowflake_query.ps1 (Windows); see either wrapper's header for usage, auth modes and env vars.
# Needs Python 3.8+ with snowflake-connector-python (imported only once the query has passed
# every check, so a refusal needs nothing beyond the stdlib).
#
# Read-only model: every query runs as traceforce_lakehouse_reader with SECONDARY ROLES NONE, so
# a connecting user's broader roles do not leak through. The preamble and the query are
# submitted as one request with the exact statement count, so Snowflake's own parser rejects a
# smuggled extra statement. The forms that could re-enable a broader role inside one parsed
# statement are refused below: the ->> operator, a non-read first keyword (Scripting blocks,
# EXECUTE IMMEDIATE) and a bare PROCEDURE/CALL token (anonymous caller's-rights procedure). A
# query user that holds only the reader role is the other half of the guarantee.
import csv
import errno
import os
import re
import sys
import traceback

DB = "traceforce_lakehouse"
SCHEMA = "traceforce"
WAREHOUSE = "traceforce_lakehouse"
READER_ROLE = "traceforce_lakehouse_reader"
READ_KEYWORDS = ("SELECT", "WITH", "SHOW", "DESCRIBE", "DESC", "EXPLAIN")
KEY_PAIR_VARS = (
    "SNOWFLAKE_ORGANIZATION_NAME",
    "SNOWFLAKE_ACCOUNT_NAME",
    "SNOWFLAKE_USER",
    "SNOWFLAKE_AUTHENTICATOR",
    "SNOWFLAKE_PRIVATE_KEY",
)
# 604800 (7 days) is Snowflake's hard maximum for STATEMENT_TIMEOUT_IN_SECONDS.
MAX_STATEMENT_TIMEOUT = 604800


class Exit(Exception):
    """A deliberate stop: main() prints the message on stderr and returns the code."""

    def __init__(self, message, code):
        super().__init__(message)
        self.message = message
        self.code = code


def usage():
    # The wrappers pass their own name so the message names the script the user ran.
    prog = os.environ.get("SNOWFLAKE_QUERY_PROG") or os.path.basename(sys.argv[0]) or "snowflake_query.py"
    return 'usage: %s "SQL" | -f file.sql' % prog


def read_max_rows(env):
    value = env.get("TRACEFORCE_LAKEHOUSE_MAX_ROWS") or "200"
    if not re.fullmatch("[0-9]+", value):
        raise Exit("invalid TRACEFORCE_LAKEHOUSE_MAX_ROWS: %s -- must be a non-negative integer" % value, 2)
    return int(value)


def read_statement_timeout(env):
    value = env.get("TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT") or "300"
    if not re.fullmatch("[0-9]+", value):
        raise Exit("invalid TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT: %s -- must be a non-negative integer" % value, 2)
    if int(value) > MAX_STATEMENT_TIMEOUT:
        raise Exit(
            "invalid TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT: %s -- must be <= 604800 (Snowflake's own max, 7 days)" % value,
            2,
        )
    return int(value)


def read_query(argv):
    """The query as raw bytes: "<SQL>" or -f <file>. Decoding is checked separately."""
    if argv and argv[0] == "-f":
        if len(argv) != 2 or not argv[1]:
            raise Exit(usage(), 2)
        try:
            with open(argv[1], "rb") as f:
                raw = f.read()
        except OSError as e:
            raise Exit("cannot read %s: %s" % (argv[1], e.strerror or e), 2)
    elif len(argv) == 1:
        # argv is already text; fsencode gives back the bytes the shell passed (surrogateescape).
        raw = os.fsencode(argv[0])
    else:
        raise Exit(usage(), 2)
    if not raw:
        raise Exit(usage(), 2)
    return raw


def decode_query(raw):
    """UTF-8 text with a leading BOM dropped and CR/CRLF read as newlines, as a text-mode file
    read would; so a bare CR never reaches the scanner or Snowflake."""
    try:
        sql = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise Exit("refusing to run: the query text is not valid UTF-8", 2)
    return sql.lstrip("\ufeff").replace("\r\n", "\n").replace("\r", "\n")


def scan(sql):
    """Bare tokens (outside string literals, quoted identifiers and comments): returns the first
    keyword, uppercased, and a flag -- "linesep" for a control/Unicode line separator,
    "procedure" for a PROCEDURE or CALL token anywhere, "" otherwise. The separators are refused
    so this scanner never has to agree with Snowflake's lexer about where a comment ends."""
    if re.search("[\x0b\x0c\x1c\x1d\x1e\x85\u2028\u2029]", sql):
        return "", "linesep"
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
        elif c == "'" or c == '"':
            j = i + 1
            while j < n:
                if c == "'" and sql[j] == "\\":
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
    first = words[0] if words else ""
    return first, ("procedure" if "PROCEDURE" in words or "CALL" in words else "")


def check_query(raw):
    """Every refusal, in order; returns the SQL text to run."""
    # ->> chains full statements (USE ROLE, DML) into one parsed statement. A plain substring
    # check, so it cannot hide inside a quote or comment.
    if b"->>" in raw:
        raise Exit(
            "refusing to run: the Snowflake pipe operator (->>) can chain a read into privileged statements as one"
            " Snowflake-parsed statement -- not allowed here (to search stored text for those characters, split the"
            " literal: LIKE '%-' || '>>%')",
            2,
        )
    sql = decode_query(raw)
    first, flag = scan(sql)
    if flag == "linesep":
        raise Exit(
            "refusing to run: the query contains a control or Unicode line-separator character (U+000B, U+000C,"
            " U+001C-U+001E, U+0085, U+2028 or U+2029); use plain newlines",
            2,
        )
    if first not in READ_KEYWORDS:
        raise Exit("refusing to run a non-read statement (first keyword: %s)" % (first or "none found"), 2)
    # A column or JSON key named call/procedure has to be double-quoted.
    if flag == "procedure":
        raise Exit(
            "refusing to run: the statement contains a bare CALL or PROCEDURE token; an anonymous WITH ... AS"
            " PROCEDURE ... CALL block runs with the caller's full rights as one Snowflake-parsed statement, so"
            " neither keyword is allowed here (double-quote a column or JSON key named call/procedure)",
            2,
        )
    return sql


def validate_env(env):
    """Key-pair auth needs all five variables; none means connections.toml. A partial set is
    refused because the default connection could be another account. Returns True for key-pair."""
    missing = [v for v in KEY_PAIR_VARS if not env.get(v)]
    if not missing:
        # The connector forces key-pair auth whenever a private key is given, so any other value
        # here would be silently ignored; refuse it instead.
        if env["SNOWFLAKE_AUTHENTICATOR"].upper() != "SNOWFLAKE_JWT":
            raise Exit(
                "SNOWFLAKE_AUTHENTICATOR must be SNOWFLAKE_JWT for key-pair auth (got: %s); unset all five"
                " SNOWFLAKE_* variables to use connections.toml instead" % env["SNOWFLAKE_AUTHENTICATOR"],
                2,
            )
        return True
    if len(missing) == len(KEY_PAIR_VARS):
        return False
    raise Exit(
        "partial key-pair env var set -- missing: %s\nset all five (listed in this script's header) or none to use"
        " connections.toml instead" % " ".join(missing),
        2,
    )


def build_preamble(statement_timeout):
    # TIMEZONE is pinned to UTC because the account default is America/Los_Angeles and
    # CURRENT_TIMESTAMP()/CURRENT_DATE() resolve in the session zone; the ts columns are UTC.
    # STATEMENT_TIMEOUT_IN_SECONDS is the runaway-cost guard: the shared warehouse's resource
    # monitor is notify-only so it never suspends the ingest/export Tasks.
    return (
        'USE ROLE "%s"; USE SECONDARY ROLES NONE; USE WAREHOUSE "%s"; USE DATABASE "%s"; USE SCHEMA "%s";'
        " ALTER SESSION SET TIMEZONE = 'UTC'; ALTER SESSION SET STATEMENT_TIMEOUT_IN_SECONDS = %d"
        % (READER_ROLE, WAREHOUSE, DB, SCHEMA, statement_timeout)
    )


def import_connector():
    """A missing package gets the install command, a broken one (e.g. a cryptography/pyOpenSSL
    mismatch) gets its real last line."""
    try:
        import snowflake.connector
    except Exception as e:
        last = traceback.format_exception_only(type(e), e)[-1].strip()
        if "No module named" in last:
            raise Exit("snowflake-connector-python is not installed: pip install snowflake-connector-python", 2)
        raise Exit("snowflake-connector-python failed to import: %s" % last, 2)
    return snowflake.connector


def load_der_key(env):
    # The connector wants DER PKCS8 bytes; the env var (shared with the Terraform provider) holds PEM text.
    from cryptography.hazmat.primitives import serialization

    pem = env["SNOWFLAKE_PRIVATE_KEY"].encode()
    try:
        key = serialization.load_pem_private_key(pem, password=None)
    except TypeError:
        # cryptography raises TypeError for an encrypted key when no password is given.
        raise Exit(
            "SNOWFLAKE_PRIVATE_KEY is an encrypted key; this script takes an unencrypted PEM in the environment."
            " For an encrypted key use a connections.toml connection (private_key_file + private_key_file_pwd).",
            2,
        )
    except ValueError as e:
        raise Exit("invalid SNOWFLAKE_PRIVATE_KEY: %s" % e, 2)
    return key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def run(connector, sql, preamble, max_rows, have_env_creds, env=os.environ):
    """Connect, submit preamble + query as one request, print CSV. Returns the exit code."""
    # The preamble is fixed text, so splitting on ";" counts its statements; the query's count is left to Snowflake.
    num_statements = sum(1 for s in preamble.split(";") if s.strip()) + 1
    try:
        if have_env_creds:
            con = connector.connect(
                account="%s-%s" % (env["SNOWFLAKE_ORGANIZATION_NAME"], env["SNOWFLAKE_ACCOUNT_NAME"]),
                user=env["SNOWFLAKE_USER"],
                private_key=load_der_key(env),
                authenticator=env["SNOWFLAKE_AUTHENTICATOR"],
            )
        else:
            # No arguments: the connector resolves the default connections.toml connection itself.
            con = connector.connect()
        cur = con.cursor()
        cur.execute("%s; %s" % (preamble, sql), num_statements=num_statements)

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
    except (connector.errors.Error, ValueError, TypeError) as e:
        # errno 8 is the statement-count mismatch: Snowflake rejected the whole request, preamble included.
        # The base Error class covers connect()-time failures as well as query errors.
        if getattr(e, "errno", None) == 8:
            raise Exit("refusing to run more than one statement -- run one query at a time", 2)
        raise Exit(str(e), 1)

    if not rows:
        print("-- 0 rows", file=sys.stderr)
        return 0

    # rowcount is None for result types that carry no total; then only "more exist" is known.
    exact_total = total is not None
    if total is None:
        total = len(rows)
    out_rows = rows if max_rows == 0 else rows[:max_rows]
    # Slicing rows (not CSV lines) keeps the cutoff on a row boundary even with multi-line fields.
    try:
        # UTF-8 and "\n" line endings on every platform, not the console code page or CRLF.
        sys.stdout.reconfigure(encoding="utf-8", newline="\n")
        w = csv.writer(sys.stdout, lineterminator="\n")
        w.writerow(columns)
        w.writerows(out_rows)
        sys.stdout.flush()
    except OSError as e:
        if not isinstance(e, BrokenPipeError) and e.errno != errno.EINVAL:
            raise
        # The reader (e.g. head) closed stdout (Windows reports that as EINVAL): stop quietly
        # instead of printing a traceback, including from the interpreter's final flush.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        return 0
    if max_rows != 0 and total > max_rows:
        shown = (
            "-- showing %d of %d rows" % (max_rows, total)
            if exact_total
            else "-- showing %d rows; more exist" % max_rows
        )
        print("%s; set TRACEFORCE_LAKEHOUSE_MAX_ROWS=0 for all" % shown, file=sys.stderr)
    return 0


def main(argv):
    try:
        max_rows = read_max_rows(os.environ)
        statement_timeout = read_statement_timeout(os.environ)
        sql = check_query(read_query(argv))
        have_env_creds = validate_env(os.environ)
        preamble = build_preamble(statement_timeout)
        connector = import_connector()
        return run(connector, sql, preamble, max_rows, have_env_creds)
    except Exit as e:
        print(e.message, file=sys.stderr)
        return e.code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
