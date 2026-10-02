#!/usr/bin/env python3
"""Tests for skills/traceforce-lakehouse/scripts/snowflake_query.py and its two launchers.

    python3 tools/test_snowflake_query.py

Stdlib only. The module is imported by path; snowflake.connector and cryptography are stubbed in
sys.modules (or replaced by a stub package on PYTHONPATH for the subprocess tests), so nothing
here ever talks to Snowflake. A few tests use the real cryptography package when it is
installed, and the PowerShell launcher is exercised only when /usr/local/bin/pwsh-preview exists.
"""
import contextlib
import errno
import importlib.util
import io
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import types
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "traceforce-lakehouse" / "scripts"
MODULE_PATH = SCRIPTS / "snowflake_query.py"
SH = SCRIPTS / "snowflake_query.sh"
PS1 = SCRIPTS / "snowflake_query.ps1"
PWSH = "/usr/local/bin/pwsh-preview"

PREAMBLE_300 = (
    'USE ROLE "traceforce_lakehouse_reader"; USE SECONDARY ROLES NONE;'
    ' USE WAREHOUSE "traceforce_lakehouse"; USE DATABASE "traceforce_lakehouse"; USE SCHEMA "traceforce";'
    " ALTER SESSION SET TIMEZONE = 'UTC'; ALTER SESSION SET STATEMENT_TIMEOUT_IN_SECONDS = 300"
)
FIVE = {
    "SNOWFLAKE_ORGANIZATION_NAME": "myorg",
    "SNOWFLAKE_ACCOUNT_NAME": "myacct",
    "SNOWFLAKE_USER": "reader",
    "SNOWFLAKE_AUTHENTICATOR": "SNOWFLAKE_JWT",
    "SNOWFLAKE_PRIVATE_KEY": "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n",
}
SEPARATORS = ["\x0b", "\x0c", "\x1c", "\x1d", "\x1e", "\x85", " ", " "]

sys.dont_write_bytecode = True
MODULES_BEFORE_LOAD = set(sys.modules)


def load_module():
    spec = importlib.util.spec_from_file_location("snowflake_query_under_test", str(MODULE_PATH))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


sq = load_module()
# Taken right after the load, before anything else (e.g. a skipUnless probe) imports packages.
MODULES_AFTER_LOAD = set(sys.modules)


# ----------------------------------------------------------------------------- stubs and helpers


class StubError(Exception):
    """Stands in for snowflake.connector.errors.Error (which carries .errno)."""

    def __init__(self, message, errno=None):
        super().__init__(message)
        self.errno = errno


class StubCursor:
    def __init__(self, rows=(), rowcount=None, description=(("A",),), execute_exc=None):
        self.rows = list(rows)
        self.rowcount = rowcount
        self.description = list(description)
        self.execute_exc = execute_exc
        self.executed = []
        self.nextsets = 0
        self.fetchmany_n = None
        self.fetchall_called = False

    def execute(self, text, num_statements=None):
        self.executed.append((text, num_statements))
        if self.execute_exc is not None:
            raise self.execute_exc

    def nextset(self):
        self.nextsets += 1
        return True

    def fetchmany(self, n):
        self.fetchmany_n = n
        return self.rows[:n]

    def fetchall(self):
        self.fetchall_called = True
        return list(self.rows)


def make_connector(cursor=None, connect_exc=None):
    """A module-shaped object with connect() and errors.Error, as run() uses it."""
    connector = types.ModuleType("snowflake.connector")
    connector.errors = types.SimpleNamespace(Error=StubError)
    connector.calls = []

    def connect(**kwargs):
        connector.calls.append(kwargs)
        if connect_exc is not None:
            raise connect_exc
        return types.SimpleNamespace(cursor=lambda: cursor)

    connector.connect = connect
    return connector


@contextlib.contextmanager
def installed_connector(connector):
    """Put the stub where `import snowflake.connector` finds it; restore afterwards."""
    saved = {n: sys.modules.get(n) for n in ("snowflake", "snowflake.connector")}
    pkg = types.ModuleType("snowflake")
    pkg.__path__ = []
    pkg.connector = connector
    sys.modules["snowflake"] = pkg
    sys.modules["snowflake.connector"] = connector
    try:
        yield
    finally:
        for name, mod in saved.items():
            if mod is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = mod


class RaisingFinder:
    """A meta-path finder that makes importing one module (and its children) raise."""

    def __init__(self, name, exc):
        self.name = name
        self.exc = exc

    def find_spec(self, fullname, path=None, target=None):
        if fullname == self.name or fullname.startswith(self.name + "."):
            raise self.exc
        return None


@contextlib.contextmanager
def failing_import(name, exc, parent_stub=False):
    saved = {n: m for n, m in sys.modules.items() if n == "snowflake" or n.startswith("snowflake.")}
    for n in saved:
        del sys.modules[n]
    if parent_stub:
        pkg = types.ModuleType("snowflake")
        pkg.__path__ = []
        sys.modules["snowflake"] = pkg
    finder = RaisingFinder(name, exc)
    sys.meta_path.insert(0, finder)
    try:
        yield
    finally:
        sys.meta_path.remove(finder)
        for n in [n for n in sys.modules if n == "snowflake" or n.startswith("snowflake.")]:
            del sys.modules[n]
        sys.modules.update(saved)


CRYPTO_NAMES = (
    "cryptography",
    "cryptography.hazmat",
    "cryptography.hazmat.primitives",
    "cryptography.hazmat.primitives.serialization",
)


@contextlib.contextmanager
def stub_cryptography(load_pem_private_key):
    """Replace cryptography.hazmat.primitives.serialization with a stub whose
    load_pem_private_key is the given callable."""
    saved = {n: sys.modules.get(n) for n in CRYPTO_NAMES}
    mods = {n: types.ModuleType(n) for n in CRYPTO_NAMES}
    for m in mods.values():
        m.__path__ = []
    ser = mods[CRYPTO_NAMES[-1]]
    ser.load_pem_private_key = load_pem_private_key
    ser.Encoding = types.SimpleNamespace(DER="DER")
    ser.PrivateFormat = types.SimpleNamespace(PKCS8="PKCS8")
    ser.NoEncryption = lambda: "NoEncryption"
    mods[CRYPTO_NAMES[-2]].serialization = ser
    sys.modules.update(mods)
    try:
        yield ser
    finally:
        for n, m in saved.items():
            if m is None:
                sys.modules.pop(n, None)
            else:
                sys.modules[n] = m


class FakeKey:
    def __init__(self):
        self.args = None

    def private_bytes(self, encoding, format, encryption_algorithm):
        self.args = (encoding, format, encryption_algorithm)
        return b"DER-BYTES"


class Captured:
    stdout = b""
    stderr = ""


@contextlib.contextmanager
def captured():
    """Capture stdout as bytes and stderr as text. stdout starts as an ASCII, CRLF text stream
    so the output proves the module reconfigured it to UTF-8 with LF line endings."""
    cap = Captured()
    buf = io.BytesIO()
    out = io.TextIOWrapper(buf, encoding="ascii", newline="\r\n", write_through=True)
    err = io.StringIO()
    with mock.patch.object(sys, "stdout", out), mock.patch.object(sys, "stderr", err):
        try:
            yield cap
        finally:
            out.flush()
            cap.stdout = buf.getvalue()
            cap.stderr = err.getvalue()
            out.detach()


class FailingRaw(io.RawIOBase):
    """A writable raw stream whose first write raises the given OSError, then succeeds."""

    def __init__(self, exc):
        super().__init__()
        self.exc = exc
        self.failed = False
        self.fd = os.open(os.devnull, os.O_WRONLY)

    def writable(self):
        return True

    def write(self, b):
        if not self.failed:
            self.failed = True
            raise self.exc
        return len(b)

    def fileno(self):
        return self.fd

    def close(self):
        if not self.closed:
            os.close(self.fd)
        super().close()


def clean_env(**extra):
    """The parent environment without any SNOWFLAKE_*/TRACEFORCE_LAKEHOUSE_* settings."""
    env = {
        k: v
        for k, v in os.environ.items()
        if not k.startswith("SNOWFLAKE_") and not k.startswith("TRACEFORCE_LAKEHOUSE_") and k != "TF_TEST_STUB_MODE"
    }
    env.update(extra)
    return env


# ----------------------------------------------------------------------------- unit tests


class ModuleShapeTests(unittest.TestCase):
    def test_importing_the_module_does_not_import_the_connector_or_cryptography(self):
        for name in ("snowflake", "snowflake.connector", "cryptography"):
            if name not in MODULES_BEFORE_LOAD:
                self.assertNotIn(name, MODULES_AFTER_LOAD, "%s was imported at module load" % name)

    def test_read_keywords_and_names(self):
        self.assertEqual(sq.READ_KEYWORDS, ("SELECT", "WITH", "SHOW", "DESCRIBE", "DESC", "EXPLAIN"))
        self.assertEqual(sq.READER_ROLE, "traceforce_lakehouse_reader")
        self.assertEqual(sq.MAX_STATEMENT_TIMEOUT, 604800)


class MaxRowsTests(unittest.TestCase):
    def read(self, value):
        return sq.read_max_rows({} if value is None else {"TRACEFORCE_LAKEHOUSE_MAX_ROWS": value})

    def refuse(self, value):
        with self.assertRaises(sq.Exit) as cm:
            self.read(value)
        self.assertEqual(cm.exception.code, 2)
        self.assertEqual(
            cm.exception.message,
            "invalid TRACEFORCE_LAKEHOUSE_MAX_ROWS: %s -- must be a non-negative integer" % value,
        )

    def test_default_and_empty(self):
        self.assertEqual(self.read(None), 200)
        self.assertEqual(self.read(""), 200)

    def test_valid_values(self):
        self.assertEqual(self.read("0"), 0)
        self.assertEqual(self.read("1"), 1)
        self.assertEqual(self.read("007"), 7)  # base 10, never octal
        self.assertEqual(self.read("00"), 0)
        self.assertEqual(self.read("1" * 25), int("1" * 25))

    def test_invalid_values(self):
        for v in ("-1", "abc", "1e3", " 5", "5 ", "1.0", "+5", "٣"):
            self.refuse(v)


class StatementTimeoutTests(unittest.TestCase):
    def read(self, value):
        return sq.read_statement_timeout({} if value is None else {"TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT": value})

    def refuse(self, value, tail):
        with self.assertRaises(sq.Exit) as cm:
            self.read(value)
        self.assertEqual(cm.exception.code, 2)
        self.assertEqual(cm.exception.message, "invalid TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT: %s -- %s" % (value, tail))

    def test_default_and_empty(self):
        self.assertEqual(self.read(None), 300)
        self.assertEqual(self.read(""), 300)

    def test_bounds(self):
        self.assertEqual(self.read("0"), 0)
        self.assertEqual(self.read("604800"), 604800)
        self.assertEqual(self.read("0000604800"), 604800)
        self.assertEqual(self.read("08"), 8)  # the bash octal trap; base 10 here
        self.refuse("604801", "must be <= 604800 (Snowflake's own max, 7 days)")
        self.refuse("9" * 19, "must be <= 604800 (Snowflake's own max, 7 days)")
        self.refuse("1" + "0" * 40, "must be <= 604800 (Snowflake's own max, 7 days)")

    def test_not_an_integer(self):
        for v in ("-1", "5m", "1.5", " 1", "1 "):
            self.refuse(v, "must be a non-negative integer")

    def test_max_rows_checked_before_timeout(self):
        env = {"TRACEFORCE_LAKEHOUSE_MAX_ROWS": "x", "TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT": "y"}
        with mock.patch.dict(os.environ, env, clear=False), captured() as cap:
            self.assertEqual(sq.main(["SELECT 1"]), 2)
        self.assertIn("invalid TRACEFORCE_LAKEHOUSE_MAX_ROWS: x", cap.stderr)
        self.assertNotIn("STATEMENT_TIMEOUT", cap.stderr)


class ReadQueryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def write(self, name, data):
        p = os.path.join(self.tmp, name)
        with open(p, "wb") as f:
            f.write(data)
        return p

    def usage(self, argv):
        with self.assertRaises(sq.Exit) as cm:
            sq.read_query(argv)
        self.assertEqual(cm.exception.code, 2)
        self.assertTrue(cm.exception.message.startswith("usage: "), cm.exception.message)
        self.assertIn('"SQL" | -f file.sql', cm.exception.message)

    def test_usage_errors(self):
        self.usage([])
        self.usage([""])
        self.usage(["-f"])
        self.usage(["-f", ""])
        self.usage(["-f", self.write("a.sql", b"SELECT 1"), "extra"])
        self.usage(["SELECT 1", "SELECT 2"])
        self.usage(["-f", self.write("empty.sql", b"")])

    def test_inline_is_returned_as_bytes(self):
        self.assertEqual(sq.read_query(["SELECT 'héllo'"]), "SELECT 'héllo'".encode("utf-8"))

    def test_file_is_read_as_raw_bytes(self):
        p = self.write("q.sql", b"\xef\xbb\xbfSELECT 1\r\n")
        self.assertEqual(sq.read_query(["-f", p]), b"\xef\xbb\xbfSELECT 1\r\n")

    def test_missing_file(self):
        with self.assertRaises(sq.Exit) as cm:
            sq.read_query(["-f", os.path.join(self.tmp, "nope.sql")])
        self.assertEqual(cm.exception.code, 2)
        self.assertTrue(cm.exception.message.startswith("cannot read "), cm.exception.message)

    def test_a_file_literally_named_dash_f_is_not_special_as_second_arg(self):
        p = self.write("-f", b"SELECT 1")
        self.assertEqual(sq.read_query(["-f", p]), b"SELECT 1")


class DecodeQueryTests(unittest.TestCase):
    def test_bom_and_line_endings(self):
        self.assertEqual(sq.decode_query(b"\xef\xbb\xbfSELECT 1"), "SELECT 1")
        self.assertEqual(sq.decode_query(b"SELECT 1\r\nFROM t\rWHERE 1"), "SELECT 1\nFROM t\nWHERE 1")

    def test_non_utf8(self):
        with self.assertRaises(sq.Exit) as cm:
            sq.decode_query(b"SELECT '\xff\xfe'")
        self.assertEqual(cm.exception.code, 2)
        self.assertEqual(cm.exception.message, "refusing to run: the query text is not valid UTF-8")


class ScannerTests(unittest.TestCase):
    """check_query: every class of accepted and refused statement."""

    def ok(self, sql):
        raw = sql if isinstance(sql, bytes) else sql.encode("utf-8")
        return sq.check_query(raw)

    def refuse(self, sql, contains):
        raw = sql if isinstance(sql, bytes) else sql.encode("utf-8")
        with self.assertRaises(sq.Exit) as cm:
            sq.check_query(raw)
        self.assertEqual(cm.exception.code, 2, cm.exception.message)
        self.assertIn(contains, cm.exception.message)
        return cm.exception.message

    # -- accepted

    def test_plain_reads(self):
        for sql in (
            "SELECT 1",
            "select count(*) from \"agent_events\"",
            "  \n\t SELECT 1",
            "SELECT* FROM t",
            "SHOW TABLES",
            "DESCRIBE TABLE \"agent_events\"",
            "DESC TABLE t",
            "EXPLAIN SELECT 1",
            "EXPLAIN USING TEXT SELECT 1",
            "WITH x AS (SELECT 1 AS a) SELECT * FROM x",
            "with recursive x as (select 1) select * from x",
            "SELECT 1;",
            "SELECT 1\n",
        ):
            self.assertEqual(self.ok(sql), sql, sql)

    def test_comments_before_and_inside(self):
        self.ok("-- a comment\nSELECT 1")
        self.ok("// a comment\nSELECT 1")
        self.ok("/* a comment */ SELECT 1")
        self.ok("/* multi\nline */\n-- more\nSELECT 1")
        self.ok("-- CALL p() is fine in a comment\nSELECT 1 -- PROCEDURE too")
        self.ok("// call procedure\nSELECT 1")
        self.ok("/* call procedure DELETE */ SELECT 1")
        self.ok("SELECT 1 /* call */ FROM t /* procedure */")
        self.ok("SELECT 1 -- call\n")

    def test_quoted_identifiers_and_literals_holding_keywords(self):
        self.ok('SELECT "call", "procedure" FROM t')
        self.ok('SELECT t."call" FROM "procedure" t')
        self.ok("SELECT 'call procedure' FROM t")
        self.ok("SELECT 'it''s a call' FROM t")
        self.ok("SELECT 'a\\'call' FROM t")
        self.ok('SELECT "a""call" FROM t')
        self.ok("SELECT 'line1\nCALL p()\nline3' FROM t")
        self.ok("SELECT $$call procedure$$ FROM t")
        self.ok("SELECT $$ multi\nline CALL $$ FROM t")
        self.ok("SELECT 'insert delete drop' FROM t")
        self.ok('SELECT * FROM t WHERE json:"call" = 1')  # the quoted path element form the message asks for

    def test_bom_is_stripped(self):
        self.assertEqual(self.ok("﻿SELECT 1"), "SELECT 1")
        self.assertEqual(self.ok(b"\xef\xbb\xbfSELECT 1"), "SELECT 1")

    def test_crlf_and_cr_become_newlines(self):
        self.assertEqual(self.ok("SELECT 1\r\nFROM t"), "SELECT 1\nFROM t")
        self.assertEqual(self.ok("SELECT 1\rFROM t"), "SELECT 1\nFROM t")

    def test_bare_cr_ends_a_line_comment(self):
        # A lone CR is a newline for the scanner, as for a text-mode read: the CALL is seen.
        self.refuse("SELECT 1 -- comment\rCALL p()", "bare CALL or PROCEDURE")

    def test_identifier_chars_with_dollar(self):
        self.ok("SELECT $1, $col FROM t")
        self.ok("SELECT my$call FROM t")  # one token, not CALL

    def test_multiple_statements_are_left_to_snowflakes_count(self):
        # The scanner only looks at the first keyword; errno 8 from Snowflake covers this.
        self.ok("SELECT 1; DELETE FROM t")

    def test_unterminated_trailing_constructs_pass_to_snowflakes_parser(self):
        # An unterminated literal/comment after a read keyword swallows the rest; Snowflake then
        # rejects the syntax. Nothing can hide a CALL in there without also being a syntax error.
        self.ok("SELECT 'abc CALL p()")
        self.ok("SELECT /* abc CALL p()")
        self.ok("SELECT $$ CALL p()")

    # -- refused: first keyword

    def test_dml_and_ddl_first_keyword(self):
        for sql, kw in (
            ("INSERT INTO t VALUES (1)", "INSERT"),
            ("UPDATE t SET a = 1", "UPDATE"),
            ("DELETE FROM t", "DELETE"),
            ("MERGE INTO t USING s ON 1=1 WHEN MATCHED THEN DELETE", "MERGE"),
            ("TRUNCATE TABLE t", "TRUNCATE"),
            ("CREATE TABLE t (a INT)", "CREATE"),
            ("DROP TABLE t", "DROP"),
            ("ALTER SESSION SET TIMEZONE = 'UTC'", "ALTER"),
            ("USE ROLE ACCOUNTADMIN", "USE"),
            ("GRANT ROLE x TO USER y", "GRANT"),
            ("CALL p()", "CALL"),
            ("COPY INTO t FROM @s", "COPY"),
            ("PUT file:///x @s", "PUT"),
            ("GET @s file:///x", "GET"),
            ("LIST @s", "LIST"),
            ("REMOVE @s", "REMOVE"),
            ("UNSET x", "UNSET"),
            ("SET x = 1", "SET"),
            ("COMMIT", "COMMIT"),
            ("  -- comment\n  insert into t values (1)", "INSERT"),
            ("/* SELECT */ DELETE FROM t", "DELETE"),
            ("'SELECT' 1", "1"),  # the literal is skipped; the first bare token is 1
            ("\"SELECT\" FROM t", "FROM"),  # a quoted identifier is not a keyword
            ("x SELECT 1", "X"),
        ):
            self.refuse(sql, "refusing to run a non-read statement (first keyword: %s)" % kw)

    def test_leading_parenthesis_is_skipped(self):
        # Punctuation is not a token, so "(SELECT 1)" starts with SELECT and is accepted.
        self.ok("(SELECT 1)")
        self.ok("(SELECT 1) UNION (SELECT 2)")

    def test_empty_or_comment_only_input(self):
        self.refuse("   ", "first keyword: none found")
        self.refuse("-- nothing here", "first keyword: none found")
        self.refuse("/* nothing */", "first keyword: none found")
        self.refuse("/* unterminated comment SELECT 1", "first keyword: none found")
        self.refuse("'unterminated literal SELECT 1", "first keyword: none found")
        self.refuse("$$ unterminated dollar SELECT 1", "first keyword: none found")
        self.refuse("﻿", "first keyword: none found")
        self.refuse(";", "first keyword: none found")

    def test_scripting_blocks(self):
        self.refuse("BEGIN\n  SELECT 1;\nEND", "first keyword: BEGIN")
        self.refuse("begin select 1; end", "first keyword: BEGIN")
        self.refuse("DECLARE x INT; BEGIN x := 1; END", "first keyword: DECLARE")
        self.refuse("EXECUTE IMMEDIATE $$ SELECT 1 $$", "first keyword: EXECUTE")
        self.refuse("EXECUTE IMMEDIATE 'USE ROLE ACCOUNTADMIN'", "first keyword: EXECUTE")
        self.refuse("execute immediate $$ begin return 1; end $$", "first keyword: EXECUTE")

    # -- refused: PROCEDURE/CALL anywhere

    def test_anonymous_procedure_sql_form(self):
        self.refuse(
            "WITH p AS PROCEDURE RETURNS INT LANGUAGE SQL AS $$ BEGIN USE ROLE ACCOUNTADMIN; RETURN 1; END $$ CALL p()",
            "bare CALL or PROCEDURE token",
        )

    def test_anonymous_procedure_javascript_form(self):
        self.refuse(
            "WITH p AS PROCEDURE RETURNS VARCHAR LANGUAGE JAVASCRIPT AS $$ return snowflake.execute({sqlText:"
            " 'USE ROLE ACCOUNTADMIN'}); $$ CALL p()",
            "bare CALL or PROCEDURE token",
        )

    def test_anonymous_procedure_lower_case_and_split_lines(self):
        self.refuse("with p as procedure returns int language sql as $$ begin return 1; end $$ call p()", "bare CALL")
        self.refuse("WITH p AS\nPROCEDURE\nRETURNS INT LANGUAGE SQL AS $$ 1 $$\nCALL\np()", "bare CALL")
        self.refuse("WITH\tp\tAS\tPROCEDURE RETURNS INT AS $$ 1 $$ CALL p()", "bare CALL")

    def test_procedure_or_call_token_alone_is_enough(self):
        self.refuse("WITH p AS PROCEDURE RETURNS INT AS $$ 1 $$ SELECT 1", "bare CALL or PROCEDURE")
        self.refuse("SELECT 1 FROM t WHERE call = 1", "bare CALL or PROCEDURE")
        self.refuse("SELECT procedure FROM t", "bare CALL or PROCEDURE")
        self.refuse("SELECT * FROM t WHERE json:call = 1", "bare CALL or PROCEDURE")
        self.refuse("SELECT $$x$$ CALL p()", "bare CALL or PROCEDURE")
        self.refuse("SELECT 'x' CALL p()", "bare CALL or PROCEDURE")
        self.refuse('SELECT "x" CALL p()', "bare CALL or PROCEDURE")
        self.refuse("SELECT 1 /* c */ CALL p()", "bare CALL or PROCEDURE")
        self.refuse("SELECT 1 -- c\nCALL p()", "bare CALL or PROCEDURE")

    def test_explain_call(self):
        self.refuse("EXPLAIN CALL p()", "bare CALL or PROCEDURE")
        self.refuse("explain call p()", "bare CALL or PROCEDURE")

    def test_first_keyword_check_precedes_procedure_check(self):
        self.refuse("CALL p()", "first keyword: CALL")
        self.refuse("CREATE PROCEDURE p() RETURNS INT AS $$ 1 $$", "first keyword: CREATE")

    def test_procedure_message_mentions_double_quoting(self):
        msg = self.refuse("SELECT call FROM t", "bare CALL")
        self.assertIn("double-quote a column or JSON key named call/procedure", msg)

    # -- refused: separators, encoding, ->>

    def test_each_refused_separator(self):
        for sep in SEPARATORS:
            msg = self.refuse("SELECT 1 -- x%sCALL p()" % sep, "line-separator character")
            self.assertIn("U+000B, U+000C, U+001C-U+001E, U+0085, U+2028 or U+2029", msg)
            self.refuse("SELECT%s1" % sep, "line-separator character")
            # Inside a literal too: the check is on the whole text.
            self.refuse("SELECT 'a%sb'" % sep, "line-separator character")

    def test_ordinary_whitespace_is_fine(self):
        self.ok("SELECT\t1\n\nFROM t")  # tab, blank lines, NBSP are not separators
        self.ok("SELECT 1 FROM t WHERE a = 'x\ty'")

    def test_non_utf8_bytes(self):
        self.refuse(b"SELECT '\xff'", "not valid UTF-8")
        self.refuse(b"SELECT 1 -- \xc3\x28", "not valid UTF-8")  # invalid continuation
        self.refuse("SELECT 'é'".encode("latin-1"), "not valid UTF-8")

    def test_separator_check_precedes_keyword_check(self):
        self.refuse("DELETE%sFROM t" % " ", "line-separator character")

    def test_pipe_operator(self):
        msg = self.refuse("SELECT 1 ->> SELECT 2", "pipe operator (->>)")
        self.assertIn("LIKE '%-' || '>>%'", msg)
        self.refuse("SELECT 1 -- ->> in a comment", "pipe operator (->>)")
        self.refuse("SELECT '->>' FROM t", "pipe operator (->>)")
        self.refuse('SELECT "->>" FROM t', "pipe operator (->>)")
        self.refuse("SELECT $$->>$$", "pipe operator (->>)")
        self.refuse("SELECT 1 - >> 2 ->>", "pipe operator (->>)")

    def test_pipe_operator_checked_on_raw_bytes_before_decoding(self):
        self.refuse(b"\xff ->>", "pipe operator (->>)")

    def test_split_literal_form_passes(self):
        sql = "SELECT * FROM t WHERE s LIKE '%-' || '>>%'"
        self.assertEqual(self.ok(sql), sql)
        self.ok("SELECT * FROM t WHERE s LIKE '%->%' OR s LIKE '%>>%'")
        self.ok("SELECT a -> 'b' FROM t")  # single arrow is not the pipe operator
        self.ok("SELECT a >> 1 FROM t")


class EnvGateTests(unittest.TestCase):
    def test_none_means_connections_toml(self):
        self.assertIs(sq.validate_env({}), False)
        self.assertIs(sq.validate_env({"OTHER": "x", "SNOWFLAKE_DEFAULT_CONNECTION_NAME": "c"}), False)

    def test_empty_values_count_as_unset(self):
        self.assertIs(sq.validate_env({v: "" for v in sq.KEY_PAIR_VARS}), False)

    def test_all_five(self):
        self.assertIs(sq.validate_env(dict(FIVE)), True)

    def test_authenticator_case_insensitive(self):
        for v in ("snowflake_jwt", "Snowflake_Jwt", "SNOWFLAKE_JWT"):
            env = dict(FIVE, SNOWFLAKE_AUTHENTICATOR=v)
            self.assertIs(sq.validate_env(env), True, v)

    def test_authenticator_mismatch(self):
        for bad in ("externalbrowser", "SNOWFLAKE", "oauth", "SNOWFLAKE_JWT "):
            with self.assertRaises(sq.Exit) as cm:
                sq.validate_env(dict(FIVE, SNOWFLAKE_AUTHENTICATOR=bad))
            self.assertEqual(cm.exception.code, 2)
            self.assertEqual(
                cm.exception.message,
                "SNOWFLAKE_AUTHENTICATOR must be SNOWFLAKE_JWT for key-pair auth (got: %s); unset all five"
                " SNOWFLAKE_* variables to use connections.toml instead" % bad,
            )

    def test_partial_set(self):
        env = dict(FIVE)
        del env["SNOWFLAKE_USER"]
        env["SNOWFLAKE_PRIVATE_KEY"] = ""
        with self.assertRaises(sq.Exit) as cm:
            sq.validate_env(env)
        self.assertEqual(cm.exception.code, 2)
        self.assertEqual(
            cm.exception.message,
            "partial key-pair env var set -- missing: SNOWFLAKE_USER SNOWFLAKE_PRIVATE_KEY\n"
            "set all five (listed in this script's header) or none to use connections.toml instead",
        )

    def test_partial_set_single_present(self):
        with self.assertRaises(sq.Exit) as cm:
            sq.validate_env({"SNOWFLAKE_USER": "u"})
        self.assertIn("missing: SNOWFLAKE_ORGANIZATION_NAME SNOWFLAKE_ACCOUNT_NAME SNOWFLAKE_AUTHENTICATOR SNOWFLAKE_PRIVATE_KEY", cm.exception.message)

    def test_partial_set_with_bad_authenticator_reports_partial_first(self):
        env = dict(FIVE, SNOWFLAKE_AUTHENTICATOR="externalbrowser")
        del env["SNOWFLAKE_PRIVATE_KEY"]
        with self.assertRaises(sq.Exit) as cm:
            sq.validate_env(env)
        self.assertIn("partial key-pair env var set", cm.exception.message)


class PreambleTests(unittest.TestCase):
    def test_text(self):
        self.assertEqual(sq.build_preamble(300), PREAMBLE_300)
        self.assertTrue(sq.build_preamble(0).endswith("STATEMENT_TIMEOUT_IN_SECONDS = 0"))
        self.assertTrue(sq.build_preamble(604800).endswith("STATEMENT_TIMEOUT_IN_SECONDS = 604800"))

    def test_statement_order(self):
        parts = [p.strip() for p in PREAMBLE_300.split(";")]
        self.assertEqual(
            parts,
            [
                'USE ROLE "traceforce_lakehouse_reader"',
                "USE SECONDARY ROLES NONE",
                'USE WAREHOUSE "traceforce_lakehouse"',
                'USE DATABASE "traceforce_lakehouse"',
                'USE SCHEMA "traceforce"',
                "ALTER SESSION SET TIMEZONE = 'UTC'",
                "ALTER SESSION SET STATEMENT_TIMEOUT_IN_SECONDS = 300",
            ],
        )

    def test_num_statements_is_preamble_plus_one(self):
        cur = StubCursor(rows=[(1,)], rowcount=1, description=[("N",)])
        with captured():
            sq.run(make_connector(cur), "SELECT 1", PREAMBLE_300, 200, False)
        self.assertEqual(cur.executed, [(PREAMBLE_300 + "; SELECT 1", 8)])
        self.assertEqual(cur.nextsets, 7)


class ImportConnectorTests(unittest.TestCase):
    def test_not_installed(self):
        with failing_import("snowflake", ModuleNotFoundError("No module named 'snowflake'")):
            with self.assertRaises(sq.Exit) as cm:
                sq.import_connector()
        self.assertEqual(cm.exception.code, 2)
        self.assertEqual(
            cm.exception.message, "snowflake-connector-python is not installed: pip install snowflake-connector-python"
        )

    def test_present_but_failing_gets_its_real_last_line(self):
        exc = ImportError("cannot import name 'X509' from 'OpenSSL.crypto' (/site-packages/OpenSSL/crypto.py)")
        with failing_import("snowflake.connector", exc, parent_stub=True):
            with self.assertRaises(sq.Exit) as cm:
                sq.import_connector()
        self.assertEqual(cm.exception.code, 2)
        self.assertEqual(
            cm.exception.message,
            "snowflake-connector-python failed to import: ImportError: cannot import name 'X509' from"
            " 'OpenSSL.crypto' (/site-packages/OpenSSL/crypto.py)",
        )

    def test_non_import_exception_is_reported_the_same_way(self):
        with failing_import("snowflake.connector", AttributeError("module 'cryptography' has no attribute 'x'"), parent_stub=True):
            with self.assertRaises(sq.Exit) as cm:
                sq.import_connector()
        self.assertEqual(
            cm.exception.message,
            "snowflake-connector-python failed to import: AttributeError: module 'cryptography' has no attribute 'x'",
        )

    def test_returns_the_module(self):
        connector = make_connector(StubCursor())
        with installed_connector(connector):
            self.assertIs(sq.import_connector(), connector)

    def test_refusals_never_need_the_connector(self):
        with failing_import("snowflake", ModuleNotFoundError("No module named 'snowflake'")):
            for argv, expected in (
                (["DELETE FROM t"], "refusing to run a non-read statement"),
                (["SELECT 1 ->> SELECT 2"], "pipe operator"),
                (["SELECT call FROM t"], "bare CALL"),
                ([], "usage:"),
            ):
                with mock.patch.dict(os.environ, clean_env(), clear=True), captured() as cap:
                    self.assertEqual(sq.main(argv), 2)
                self.assertIn(expected, cap.stderr)
                self.assertNotIn("snowflake-connector-python", cap.stderr)

    def test_env_gate_runs_before_the_import(self):
        with failing_import("snowflake", ModuleNotFoundError("No module named 'snowflake'")):
            with mock.patch.dict(os.environ, clean_env(SNOWFLAKE_USER="u"), clear=True), captured() as cap:
                self.assertEqual(sq.main(["SELECT 1"]), 2)
        self.assertIn("partial key-pair env var set", cap.stderr)
        self.assertNotIn("snowflake-connector-python", cap.stderr)

    def test_import_happens_once_everything_else_passed(self):
        with failing_import("snowflake", ModuleNotFoundError("No module named 'snowflake'")):
            with mock.patch.dict(os.environ, clean_env(), clear=True), captured() as cap:
                self.assertEqual(sq.main(["SELECT 1"]), 2)
        self.assertEqual(cap.stderr.strip(), "snowflake-connector-python is not installed: pip install snowflake-connector-python")


class RunFlowTests(unittest.TestCase):
    def run_query(self, cur, max_rows=200, sql="SELECT 1", have_env_creds=False, connector=None, env=None):
        connector = connector or make_connector(cur)
        with captured() as cap:
            if env is None:
                code = sq.run(connector, sql, PREAMBLE_300, max_rows, have_env_creds)
            else:
                code = sq.run(connector, sql, PREAMBLE_300, max_rows, have_env_creds, env=env)
        return code, cap, connector

    def test_normal_result(self):
        cur = StubCursor(rows=[(1, "a"), (2, "b"), (3, "c")], rowcount=3, description=[("ID",), ("NAME",)])
        code, cap, connector = self.run_query(cur)
        self.assertEqual(code, 0)
        self.assertEqual(cap.stdout, b"ID,NAME\n1,a\n2,b\n3,c\n")
        self.assertEqual(cap.stderr, "")
        self.assertEqual(cur.fetchmany_n, 201)
        self.assertFalse(cur.fetchall_called)
        self.assertEqual(connector.calls, [{}])  # connections.toml mode: connect() with no arguments

    def test_execute_text_is_preamble_semicolon_space_sql(self):
        cur = StubCursor(rows=[(1,)], rowcount=1)
        sql = "SELECT 1\nFROM t -- trailing"
        self.run_query(cur, sql=sql)
        self.assertEqual(cur.executed[0][0], PREAMBLE_300 + "; " + sql)

    def test_truncation_with_exact_rowcount(self):
        cur = StubCursor(rows=[(1,), (2,), (3,)], rowcount=10, description=[("N",)])
        code, cap, _ = self.run_query(cur, max_rows=2)
        self.assertEqual(code, 0)
        self.assertEqual(cap.stdout, b"N\n1\n2\n")
        self.assertEqual(cap.stderr, "-- showing 2 of 10 rows; set TRACEFORCE_LAKEHOUSE_MAX_ROWS=0 for all\n")
        self.assertEqual(cur.fetchmany_n, 3)

    def test_truncation_with_rowcount_none(self):
        cur = StubCursor(rows=[(1,), (2,), (3,)], rowcount=None, description=[("N",)])
        code, cap, _ = self.run_query(cur, max_rows=2)
        self.assertEqual(code, 0)
        self.assertEqual(cap.stdout, b"N\n1\n2\n")
        self.assertEqual(cap.stderr, "-- showing 2 rows; more exist; set TRACEFORCE_LAKEHOUSE_MAX_ROWS=0 for all\n")

    def test_rowcount_none_without_overflow_has_no_note(self):
        cur = StubCursor(rows=[(1,), (2,)], rowcount=None, description=[("N",)])
        code, cap, _ = self.run_query(cur, max_rows=2)
        self.assertEqual(code, 0)
        self.assertEqual(cap.stdout, b"N\n1\n2\n")
        self.assertEqual(cap.stderr, "")

    def test_exactly_max_rows_has_no_note(self):
        cur = StubCursor(rows=[(1,), (2,)], rowcount=2, description=[("N",)])
        code, cap, _ = self.run_query(cur, max_rows=2)
        self.assertEqual(cap.stderr, "")
        self.assertEqual(cap.stdout, b"N\n1\n2\n")

    def test_max_rows_zero_fetches_all(self):
        rows = [(i,) for i in range(500)]
        cur = StubCursor(rows=rows, rowcount=500, description=[("N",)])
        code, cap, _ = self.run_query(cur, max_rows=0)
        self.assertEqual(code, 0)
        self.assertTrue(cur.fetchall_called)
        self.assertIsNone(cur.fetchmany_n)
        self.assertEqual(cap.stdout, b"N\n" + b"".join(b"%d\n" % i for i in range(500)))
        self.assertEqual(cap.stderr, "")

    def test_zero_rows(self):
        cur = StubCursor(rows=[], rowcount=0, description=[("N",)])
        code, cap, _ = self.run_query(cur)
        self.assertEqual(code, 0)
        self.assertEqual(cap.stdout, b"")
        self.assertEqual(cap.stderr, "-- 0 rows\n")

    def test_zero_rows_with_max_rows_zero(self):
        cur = StubCursor(rows=[], rowcount=0, description=[("N",)])
        code, cap, _ = self.run_query(cur, max_rows=0)
        self.assertEqual(code, 0)
        self.assertEqual(cap.stderr, "-- 0 rows\n")

    def test_errno_8_is_a_refusal(self):
        cur = StubCursor(execute_exc=StubError("Actual statement count 9 did not match the desired statement count 8.", errno=8))
        with self.assertRaises(sq.Exit) as cm, captured() as cap:
            sq.run(make_connector(cur), "SELECT 1; SELECT 2", PREAMBLE_300, 200, False)
        self.assertEqual(cm.exception.code, 2)
        self.assertEqual(cm.exception.message, "refusing to run more than one statement -- run one query at a time")
        self.assertEqual(cap.stdout, b"")

    def test_generic_connector_error_is_exit_1_with_its_message(self):
        exc = StubError("002003 (42S02): SQL compilation error:\nObject 'NOPE' does not exist or not authorized.", errno=2003)
        cur = StubCursor(execute_exc=exc)
        with self.assertRaises(sq.Exit) as cm, captured():
            sq.run(make_connector(cur), "SELECT 1", PREAMBLE_300, 200, False)
        self.assertEqual(cm.exception.code, 1)
        self.assertEqual(cm.exception.message, str(exc))

    def test_connect_time_error_is_exit_1(self):
        connector = make_connector(connect_exc=StubError("250001 (08001): Failed to connect to DB", errno=250001))
        with self.assertRaises(sq.Exit) as cm, captured():
            sq.run(connector, "SELECT 1", PREAMBLE_300, 200, False)
        self.assertEqual(cm.exception.code, 1)
        self.assertIn("Failed to connect", cm.exception.message)

    def test_value_and_type_errors_from_connector_are_exit_1(self):
        for exc in (ValueError("bad connection name"), TypeError("unexpected keyword")):
            connector = make_connector(connect_exc=exc)
            with self.assertRaises(sq.Exit) as cm, captured():
                sq.run(connector, "SELECT 1", PREAMBLE_300, 200, False)
            self.assertEqual(cm.exception.code, 1)
            self.assertEqual(cm.exception.message, str(exc))

    def test_unexpected_exception_propagates(self):
        connector = make_connector(connect_exc=RuntimeError("boom"))
        with self.assertRaises(RuntimeError), captured():
            sq.run(connector, "SELECT 1", PREAMBLE_300, 200, False)

    def test_key_pair_connect_arguments(self):
        key = FakeKey()
        cur = StubCursor(rows=[(1,)], rowcount=1)
        env = dict(FIVE, SNOWFLAKE_AUTHENTICATOR="snowflake_jwt")
        with stub_cryptography(lambda pem, password=None: key) as ser:
            code, cap, connector = self.run_query(cur, have_env_creds=True, env=env)
        self.assertEqual(code, 0)
        self.assertEqual(
            connector.calls,
            [{"account": "myorg-myacct", "user": "reader", "private_key": b"DER-BYTES", "authenticator": "snowflake_jwt"}],
        )
        self.assertEqual(key.args, ("DER", "PKCS8", "NoEncryption"))

    def test_pem_is_passed_as_bytes_with_no_password(self):
        seen = {}

        def load(pem, password=None):
            seen["pem"] = pem
            seen["password"] = password
            return FakeKey()

        cur = StubCursor(rows=[(1,)], rowcount=1)
        with stub_cryptography(load):
            self.run_query(cur, have_env_creds=True, env=dict(FIVE))
        self.assertEqual(seen, {"pem": FIVE["SNOWFLAKE_PRIVATE_KEY"].encode(), "password": None})

    def test_csv_is_utf8_with_lf_regardless_of_stdout_defaults(self):
        cur = StubCursor(
            rows=[(1, "héllo", "line1\nline2"), (2, "日本", 'say "hi"'), (3, None, "")],
            rowcount=3,
            description=[("ID",), ("NAME",), ("NOTE",)],
        )
        code, cap, _ = self.run_query(cur)
        self.assertEqual(code, 0)
        expected = 'ID,NAME,NOTE\n1,héllo,"line1\nline2"\n2,日本,"say ""hi"""\n3,,\n'.encode("utf-8")
        self.assertEqual(cap.stdout, expected)
        self.assertNotIn(b"\r", cap.stdout)

    def test_multi_line_fields_are_cut_on_row_boundaries(self):
        cur = StubCursor(rows=[("a\nb",), ("c\nd",), ("e",)], rowcount=3, description=[("X",)])
        code, cap, _ = self.run_query(cur, max_rows=2)
        self.assertEqual(cap.stdout, b'X\n"a\nb"\n"c\nd"\n')
        self.assertEqual(cap.stderr, "-- showing 2 of 3 rows; set TRACEFORCE_LAKEHOUSE_MAX_ROWS=0 for all\n")


class BrokenPipeTests(unittest.TestCase):
    def run_with_failing_stdout(self, exc):
        raw = FailingRaw(exc)
        out = io.TextIOWrapper(io.BufferedWriter(raw), encoding="utf-8", write_through=True)
        err = io.StringIO()
        cur = StubCursor(rows=[(i,) for i in range(50)], rowcount=50, description=[("N",)])
        with mock.patch.object(sys, "stdout", out), mock.patch.object(sys, "stderr", err):
            try:
                return sq.run(make_connector(cur), "SELECT 1", PREAMBLE_300, 10, False), err
            finally:
                out.close()

    def test_broken_pipe_exits_0_quietly(self):
        code, err = self.run_with_failing_stdout(BrokenPipeError(errno.EPIPE, "Broken pipe"))
        self.assertEqual(code, 0)
        self.assertEqual(err.getvalue(), "")  # not even the truncation note

    def test_windows_einval_is_treated_as_a_closed_pipe(self):
        code, err = self.run_with_failing_stdout(OSError(errno.EINVAL, "Invalid argument"))
        self.assertEqual(code, 0)
        self.assertEqual(err.getvalue(), "")

    def test_other_os_errors_propagate(self):
        with self.assertRaises(OSError) as cm:
            self.run_with_failing_stdout(OSError(errno.ENOSPC, "No space left on device"))
        self.assertEqual(cm.exception.errno, errno.ENOSPC)


class MainFlowTests(unittest.TestCase):
    """main(): argv + os.environ in, exit code + streams out, with the connector stubbed."""

    def main(self, argv, env, cur=None, connector=None):
        connector = connector or make_connector(cur)
        with installed_connector(connector), mock.patch.dict(os.environ, clean_env(**env), clear=True):
            with captured() as cap:
                code = sq.main(argv)
        return code, cap, connector

    def test_happy_path_with_truncation(self):
        cur = StubCursor(rows=[(1,), (2,)], rowcount=3, description=[("N",)])
        code, cap, _ = self.main(["SELECT 1"], {"TRACEFORCE_LAKEHOUSE_MAX_ROWS": "1"}, cur)
        self.assertEqual(code, 0)
        self.assertEqual(cap.stdout, b"N\n1\n")
        self.assertEqual(cap.stderr, "-- showing 1 of 3 rows; set TRACEFORCE_LAKEHOUSE_MAX_ROWS=0 for all\n")
        self.assertEqual(cur.fetchmany_n, 2)

    def test_statement_timeout_reaches_the_preamble(self):
        cur = StubCursor(rows=[(1,)], rowcount=1)
        self.main(["SELECT 1"], {"TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT": "0"}, cur)
        self.assertIn("STATEMENT_TIMEOUT_IN_SECONDS = 0; SELECT 1", cur.executed[0][0])
        self.assertEqual(cur.executed[0][1], 8)

    def test_file_input_with_bom_and_crlf(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = os.path.join(tmp, "q.sql")
            with open(p, "wb") as f:
                f.write(b"\xef\xbb\xbfSELECT 1\r\nFROM t\r\n")
            cur = StubCursor(rows=[(1,)], rowcount=1)
            code, cap, _ = self.main(["-f", p], {}, cur)
        self.assertEqual(code, 0)
        self.assertTrue(cur.executed[0][0].endswith("; SELECT 1\nFROM t\n"), cur.executed[0][0])

    def test_errno_8_exit_2_and_generic_error_exit_1(self):
        cur = StubCursor(execute_exc=StubError("count mismatch", errno=8))
        code, cap, _ = self.main(["SELECT 1; SELECT 2"], {}, cur)
        self.assertEqual(code, 2)
        self.assertEqual(cap.stderr, "refusing to run more than one statement -- run one query at a time\n")
        cur = StubCursor(execute_exc=StubError("SQL compilation error", errno=2003))
        code, cap, _ = self.main(["SELECT 1"], {}, cur)
        self.assertEqual(code, 1)
        self.assertEqual(cap.stderr, "SQL compilation error\n")

    def test_encrypted_pem_stubbed(self):
        cur = StubCursor(rows=[(1,)], rowcount=1)

        def load(pem, password=None):
            raise TypeError("Password was not given but private key is encrypted")

        with stub_cryptography(load):
            code, cap, connector = self.main(["SELECT 1"], FIVE, cur)
        self.assertEqual(code, 2)
        self.assertEqual(
            cap.stderr,
            "SNOWFLAKE_PRIVATE_KEY is an encrypted key; this script takes an unencrypted PEM in the environment."
            " For an encrypted key use a connections.toml connection (private_key_file + private_key_file_pwd).\n",
        )
        self.assertEqual(connector.calls, [])  # never connected

    def test_malformed_pem_stubbed(self):
        cur = StubCursor(rows=[(1,)], rowcount=1)

        def load(pem, password=None):
            raise ValueError("Could not deserialize key data.")

        with stub_cryptography(load):
            code, cap, connector = self.main(["SELECT 1"], FIVE, cur)
        self.assertEqual(code, 2)
        self.assertEqual(cap.stderr, "invalid SNOWFLAKE_PRIVATE_KEY: Could not deserialize key data.\n")
        self.assertEqual(connector.calls, [])

    def test_key_pair_mode_passes_account_user_key(self):
        cur = StubCursor(rows=[(1,)], rowcount=1)
        with stub_cryptography(lambda pem, password=None: FakeKey()):
            code, cap, connector = self.main(["SELECT 1"], FIVE, cur)
        self.assertEqual(code, 0)
        self.assertEqual(connector.calls[0]["account"], "myorg-myacct")
        self.assertEqual(connector.calls[0]["user"], "reader")
        self.assertEqual(connector.calls[0]["private_key"], b"DER-BYTES")
        self.assertEqual(connector.calls[0]["authenticator"], "SNOWFLAKE_JWT")

    def test_authenticator_mismatch_exit_2(self):
        code, cap, connector = self.main(["SELECT 1"], dict(FIVE, SNOWFLAKE_AUTHENTICATOR="externalbrowser"), StubCursor())
        self.assertEqual(code, 2)
        self.assertIn("SNOWFLAKE_AUTHENTICATOR must be SNOWFLAKE_JWT", cap.stderr)
        self.assertEqual(connector.calls, [])

    def test_exit_codes_summary(self):
        cases = [
            ([], {}, 2),
            (["DELETE FROM t"], {}, 2),
            (["SELECT 1"], {"TRACEFORCE_LAKEHOUSE_MAX_ROWS": "-1"}, 2),
            (["SELECT 1"], {"TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT": "604801"}, 2),
            (["SELECT 1"], {"SNOWFLAKE_USER": "x"}, 2),
            (["SELECT 1"], {}, 0),
        ]
        for argv, env, expected in cases:
            cur = StubCursor(rows=[(1,)], rowcount=1)
            code, cap, _ = self.main(argv, env, cur)
            self.assertEqual(code, expected, (argv, env, cap.stderr))


def have_real_cryptography():
    try:
        import cryptography.hazmat.primitives.serialization  # noqa: F401
        from cryptography.hazmat.primitives.asymmetric import rsa  # noqa: F401
    except Exception:
        return False
    return True


@unittest.skipUnless(have_real_cryptography(), "cryptography is not installed")
class RealCryptographyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import rsa

        cls.serialization = serialization
        cls.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        cls.plain_pem = cls.key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
        ).decode()
        cls.encrypted_pem = cls.key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.BestAvailableEncryption(b"secret"),
        ).decode()

    def test_unencrypted_pem_becomes_der_pkcs8(self):
        der = sq.load_der_key(dict(FIVE, SNOWFLAKE_PRIVATE_KEY=self.plain_pem))
        self.assertIsInstance(der, bytes)
        loaded = self.serialization.load_der_private_key(der, password=None)
        self.assertEqual(loaded.private_numbers(), self.key.private_numbers())

    def test_encrypted_pem(self):
        with self.assertRaises(sq.Exit) as cm:
            sq.load_der_key(dict(FIVE, SNOWFLAKE_PRIVATE_KEY=self.encrypted_pem))
        self.assertEqual(cm.exception.code, 2)
        self.assertTrue(cm.exception.message.startswith("SNOWFLAKE_PRIVATE_KEY is an encrypted key;"), cm.exception.message)

    def test_malformed_pem(self):
        for bad in (FIVE["SNOWFLAKE_PRIVATE_KEY"], "not a key at all", ""):
            with self.assertRaises(sq.Exit) as cm:
                sq.load_der_key(dict(FIVE, SNOWFLAKE_PRIVATE_KEY=bad))
            self.assertEqual(cm.exception.code, 2, bad)
            self.assertTrue(cm.exception.message.startswith("invalid SNOWFLAKE_PRIVATE_KEY: "), cm.exception.message)

    def test_traditional_rsa_pem_is_accepted(self):
        pem = self.key.private_bytes(
            self.serialization.Encoding.PEM,
            self.serialization.PrivateFormat.TraditionalOpenSSL,
            self.serialization.NoEncryption(),
        ).decode()
        self.assertIsInstance(sq.load_der_key(dict(FIVE, SNOWFLAKE_PRIVATE_KEY=pem)), bytes)


# ----------------------------------------------------------------------------- subprocess tests

STUB_CONNECTOR = '''
"""Stub snowflake.connector for the launcher tests; TF_TEST_STUB_MODE picks the behaviour."""
import os
import re

from . import errors

MODE = os.environ.get("TF_TEST_STUB_MODE", "rows")


class Cursor(object):
    description = None
    rowcount = None

    def execute(self, text, num_statements=None):
        if MODE == "errno8":
            raise errors.Error("Actual statement count 9 did not match the desired statement count 8.", 8)
        if MODE == "error":
            raise errors.Error("002003 (42S02): SQL compilation error: Object 'NOPE' does not exist or not authorized.", 2003)
        m = re.search(r"STATEMENT_TIMEOUT_IN_SECONDS = [0-9]+; ", text)
        assert m, text
        self.sql = text[m.end():]
        self.num_statements = num_statements
        self._rows = self.make_rows()
        self.rowcount = len(self._rows)

    def make_rows(self):
        if MODE == "echo":
            self.description = [("SQL",), ("N",)]
            return [(self.sql, self.num_statements)]
        if MODE == "zero":
            self.description = [("N",)]
            return []
        if MODE == "many":
            self.description = [("N",), ("PAD",)]
            return [(i, "x" * 60) for i in range(60000)]
        self.description = [("ID",), ("NAME",), ("NOTE",)]
        return [(1, u"h\\u00e9llo", "line1\\nline2"), (2, u"\\u65e5\\u672c", 'say "hi"')]

    def nextset(self):
        return True

    def fetchmany(self, n):
        return self._rows[:n]

    def fetchall(self):
        return list(self._rows)


class Connection(object):
    def cursor(self):
        return Cursor()


def connect(**kwargs):
    if MODE == "connect_error":
        raise errors.Error("250001 (08001): Failed to connect to DB: stub", 250001)
    return Connection()
'''

STUB_ERRORS = '''
class Error(Exception):
    def __init__(self, msg, errno=None):
        Exception.__init__(self, msg)
        self.errno = errno
'''

EXPECTED_ROWS_CSV = 'ID,NAME,NOTE\n1,héllo,"line1\nline2"\n2,日本,"say ""hi"""\n'.encode("utf-8")


class LauncherTestBase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="sfq-test-")
        stub = os.path.join(cls.tmp, "stub")
        os.makedirs(os.path.join(stub, "snowflake", "connector"))
        open(os.path.join(stub, "snowflake", "__init__.py"), "w").close()
        with open(os.path.join(stub, "snowflake", "connector", "__init__.py"), "w") as f:
            f.write(STUB_CONNECTOR)
        with open(os.path.join(stub, "snowflake", "connector", "errors.py"), "w") as f:
            f.write(STUB_ERRORS)
        cls.stub = stub

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, True)

    def env(self, mode="rows", **extra):
        env = clean_env(TF_TEST_STUB_MODE=mode, PYTHONDONTWRITEBYTECODE="1", **extra)
        env["PYTHONPATH"] = self.stub + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
        return env

    def write(self, name, data, subdir=None):
        d = self.tmp if subdir is None else os.path.join(self.tmp, subdir)
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, name)
        with open(p, "wb") as f:
            f.write(data)
        return p

    def run_cmd(self, cmd, env, cwd=None, timeout=120):
        return subprocess.run(cmd, env=env, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)

    def assert_refusals(self, launch):
        """launch(argv) -> CompletedProcess; the refusal exit codes through a launcher."""
        cases = [
            ([], 2, b"usage:"),
            (["DELETE FROM t"], 2, b"refusing to run a non-read statement (first keyword: DELETE)"),
            (["SELECT 1 ->> SELECT 2"], 2, b"pipe operator (->>)"),
            (["SELECT call FROM t"], 2, b"bare CALL or PROCEDURE"),
            (["WITH p AS PROCEDURE RETURNS INT AS $$ 1 $$ CALL p()"], 2, b"bare CALL or PROCEDURE"),
            (["BEGIN SELECT 1; END"], 2, b"first keyword: BEGIN"),
            (["SELECT 1   CALL p()"], 2, b"line-separator"),
        ]
        for argv, code, needle in cases:
            r = launch(argv, self.env())
            self.assertEqual(r.returncode, code, (argv, r.stderr))
            self.assertIn(needle, r.stderr, argv)
            self.assertEqual(r.stdout, b"", argv)


class PythonModuleSubprocessTests(LauncherTestBase):
    """snowflake_query.py run directly with a stub connector package on PYTHONPATH."""

    def launch(self, argv, env, cwd=None):
        return self.run_cmd([sys.executable, str(MODULE_PATH)] + argv, env, cwd=cwd)

    def test_refusals(self):
        self.assert_refusals(self.launch)

    def test_rows_csv_bytes(self):
        r = self.launch(["SELECT 1"], self.env("rows"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, EXPECTED_ROWS_CSV)
        self.assertEqual(r.stderr, b"")

    def test_rows_csv_bytes_with_legacy_stdout_encoding(self):
        # Even when the console encoding would be cp1252/ASCII, the CSV is UTF-8 with LF.
        r = self.launch(["SELECT 1"], self.env("rows", PYTHONIOENCODING="ascii"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, EXPECTED_ROWS_CSV)

    def test_zero_rows(self):
        r = self.launch(["SELECT 1"], self.env("zero"))
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout, b"")
        self.assertEqual(r.stderr, b"-- 0 rows\n")

    def test_truncation_note(self):
        r = self.launch(["SELECT 1"], self.env("many", TRACEFORCE_LAKEHOUSE_MAX_ROWS="2"))
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout, b"N,PAD\n0," + b"x" * 60 + b"\n1," + b"x" * 60 + b"\n")
        self.assertEqual(r.stderr, b"-- showing 2 of 60000 rows; set TRACEFORCE_LAKEHOUSE_MAX_ROWS=0 for all\n")

    def test_errno_8_exit_2(self):
        r = self.launch(["SELECT 1; SELECT 2"], self.env("errno8"))
        self.assertEqual(r.returncode, 2)
        self.assertEqual(r.stderr, b"refusing to run more than one statement -- run one query at a time\n")

    def test_query_error_exit_1(self):
        r = self.launch(["SELECT 1"], self.env("error"))
        self.assertEqual(r.returncode, 1)
        self.assertIn(b"SQL compilation error", r.stderr)
        self.assertNotIn(b"Traceback", r.stderr)

    def test_connect_error_exit_1(self):
        r = self.launch(["SELECT 1"], self.env("connect_error"))
        self.assertEqual(r.returncode, 1)
        self.assertIn(b"Failed to connect", r.stderr)

    def test_env_validation_exit_2(self):
        for env in (
            self.env("rows", TRACEFORCE_LAKEHOUSE_MAX_ROWS="abc"),
            self.env("rows", TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT="604801"),
            self.env("rows", SNOWFLAKE_USER="only-one"),
        ):
            r = self.launch(["SELECT 1"], env)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertEqual(r.stdout, b"")

    def test_echo_shows_query_and_statement_count(self):
        sql = 'SELECT "Call", \'it\'\'s "fine"\', $1 FROM "t" -- tail'
        r = self.launch([sql], self.env("echo"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, ('SQL,N\n"%s",8\n' % sql.replace('"', '""')).encode("utf-8"))

    def test_file_with_bom_and_crlf(self):
        p = self.write("bom.sql", "﻿SELECT 1\r\nFROM \"t\"\r\n".encode("utf-8"))
        r = self.launch(["-f", p], self.env("echo"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, b'SQL,N\n"SELECT 1\nFROM ""t""\n",8\n')

    def test_non_utf8_file(self):
        p = self.write("latin1.sql", b"SELECT '\xe9'")
        r = self.launch(["-f", p], self.env("rows"))
        self.assertEqual(r.returncode, 2)
        self.assertIn(b"not valid UTF-8", r.stderr)

    def test_missing_connector_message_when_import_fails(self):
        broken = os.path.join(self.tmp, "broken")
        os.makedirs(os.path.join(broken, "snowflake"), exist_ok=True)
        with open(os.path.join(broken, "snowflake", "__init__.py"), "w") as f:
            f.write("raise ImportError(\"cannot import name 'X509' from 'OpenSSL.crypto'\")\n")
        env = self.env("rows")
        env["PYTHONPATH"] = broken
        r = self.launch(["SELECT 1"], env)
        self.assertEqual(r.returncode, 2)
        self.assertEqual(
            r.stderr,
            b"snowflake-connector-python failed to import: ImportError: cannot import name 'X509' from 'OpenSSL.crypto'\n",
        )

    def test_broken_pipe_is_quiet_and_exit_0(self):
        p = subprocess.Popen(
            [sys.executable, str(MODULE_PATH), "SELECT 1"],
            env=self.env("many", TRACEFORCE_LAKEHOUSE_MAX_ROWS="0"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        first = p.stdout.readline()
        p.stdout.close()  # the reader goes away mid-stream, as `| head -1` does
        _, err = p.communicate(timeout=120)
        self.assertEqual(first, b"N,PAD\n")
        self.assertEqual(p.returncode, 0, err)
        self.assertEqual(err, b"")


class BashLauncherTests(LauncherTestBase):
    def launch(self, argv, env, cwd=None):
        return self.run_cmd([str(SH)] + argv, env, cwd=cwd)

    def test_is_executable_bash_script(self):
        self.assertTrue(os.access(str(SH), os.X_OK), "snowflake_query.sh lost its executable bit")
        with open(str(SH), "rb") as f:
            first = f.readline()
        self.assertEqual(first.rstrip(), b"#!/usr/bin/env bash")

    def test_refusals(self):
        self.assert_refusals(self.launch)

    def test_rows_and_exit_codes_pass_through(self):
        r = self.launch(["SELECT 1"], self.env("rows"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, EXPECTED_ROWS_CSV)
        self.assertEqual(self.launch(["SELECT 1; SELECT 2"], self.env("errno8")).returncode, 2)
        self.assertEqual(self.launch(["SELECT 1"], self.env("error")).returncode, 1)
        r = self.launch(["SELECT 1"], self.env("zero"))
        self.assertEqual((r.returncode, r.stderr), (0, b"-- 0 rows\n"))

    def test_inline_sql_reaches_python_unchanged(self):
        sql = 'SELECT "Call", \'it\'\'s "fine"\', $1 FROM "t" -- tail'
        r = self.launch([sql], self.env("echo"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, ('SQL,N\n"%s",8\n' % sql.replace('"', '""')).encode("utf-8"))

    def test_file_argument_relative_to_cwd(self):
        self.write("rel.sql", b"SELECT 1", subdir="rel dir")
        r = self.launch(["-f", "rel.sql"], self.env("rows"), cwd=os.path.join(self.tmp, "rel dir"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, EXPECTED_ROWS_CSV)

    def test_works_when_invoked_through_a_relative_path(self):
        rel = os.path.relpath(str(SH), str(ROOT))
        r = self.run_cmd([rel, "SELECT 1"], self.env("rows"), cwd=str(ROOT))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, EXPECTED_ROWS_CSV)

    def test_missing_python3(self):
        env = self.env("rows")
        env["PATH"] = os.path.join(self.tmp, "empty-path")
        os.makedirs(env["PATH"], exist_ok=True)
        r = self.run_cmd(["/bin/bash", str(SH), "SELECT 1"], env)
        self.assertEqual(r.returncode, 2)
        self.assertEqual(r.stderr, b"python3 is required (see the header)\n")

    def test_bash_does_nothing_but_delegate(self):
        with open(str(SH), "r", encoding="utf-8") as f:
            code = [ln for ln in f.read().splitlines() if ln.strip() and not ln.startswith("#")]
        self.assertEqual(len(code), 3, code)
        self.assertEqual(code[0], "set -euo pipefail")
        self.assertIn("command -v python3", code[1])
        # The wrapper passes its own name down for the usage message, then execs the module.
        self.assertTrue(code[2].startswith('SNOWFLAKE_QUERY_PROG="${0##*/}" exec python3 '), code[2])
        self.assertIn('snowflake_query.py" "$@"', code[2])


@unittest.skipUnless(os.path.exists(PWSH), "%s is not installed" % PWSH)
class PowerShellLauncherTests(LauncherTestBase):
    def launch(self, argv, env, cwd=None):
        return self.run_cmd([PWSH, "-NoProfile", "-NonInteractive", "-File", str(PS1)] + argv, env, cwd=cwd, timeout=300)

    def test_source_is_ascii_only_and_5_1_safe(self):
        with open(str(PS1), "rb") as f:
            src = f.read()
        self.assertTrue(all(b < 128 for b in src), "snowflake_query.ps1 contains non-ASCII bytes")
        text = src.decode("ascii")
        for bad in (" ?? ", "&&", "||"):
            self.assertNotIn(bad, text, "PowerShell 7-only operator %r in the 5.1-compatible launcher" % bad)
        self.assertIn("[Environment]::Exit(130)", text)
        self.assertIn("function Quit(", text)
        self.assertIn("function Fail(", text)
        self.assertIn("trap {", text)

    def test_usage(self):
        r = self.launch([], self.env())
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn(b'usage: snowflake_query.ps1 "SQL" | -f file.sql', r.stderr)

    def test_refusals(self):
        self.assert_refusals(lambda argv, env: self.launch(argv, env) if argv else self.launch([], env))

    def test_exit_code_propagation(self):
        self.assertEqual(self.launch(["SELECT 1; SELECT 2"], self.env("errno8")).returncode, 2)
        self.assertEqual(self.launch(["SELECT 1"], self.env("error")).returncode, 1)
        self.assertEqual(self.launch(["SELECT 1"], self.env("connect_error")).returncode, 1)
        r = self.launch(["SELECT 1"], self.env("zero"))
        self.assertEqual((r.returncode, r.stderr), (0, b"-- 0 rows\n"))

    def test_rows_csv_bytes_pass_through_unchanged(self):
        r = self.launch(["SELECT 1"], self.env("rows"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, EXPECTED_ROWS_CSV)
        self.assertEqual(r.stderr, b"")

    def test_inline_quotes_and_dollars_are_preserved(self):
        sql = 'SELECT "Call", \'it\'\'s "fine"\', $1, \'$env:HOME\', \'`backtick`\' FROM "t" -- tail \\ end'
        r = self.launch([sql], self.env("echo"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, ('SQL,N\n"%s",8\n' % sql.replace('"', '""')).encode("utf-8"))

    def test_inline_unicode_and_newlines_are_preserved(self):
        sql = "SELECT 'héllo 日本'\nFROM \"t\""
        r = self.launch([sql], self.env("echo"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, ('SQL,N\n"%s",8\n' % sql.replace('"', '""')).encode("utf-8"))

    def test_file_argument_alias_and_relative_path(self):
        self.write("rel.sql", b"SELECT 1", subdir="ps rel dir")
        cwd = os.path.join(self.tmp, "ps rel dir")
        for flag in ("-f", "-File"):
            r = self.launch([flag, "rel.sql"], self.env("rows"), cwd=cwd)
            self.assertEqual(r.returncode, 0, (flag, r.stderr))
            self.assertEqual(r.stdout, EXPECTED_ROWS_CSV)

    def test_file_path_with_spaces_and_quotes_in_name(self):
        p = self.write("my query's file.sql", b"SELECT 1", subdir="dir with spaces")
        r = self.launch(["-f", p], self.env("rows"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, EXPECTED_ROWS_CSV)

    def test_missing_file_is_exit_2(self):
        r = self.launch(["-f", os.path.join(self.tmp, "nope.sql")], self.env("rows"))
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn(b"cannot read", r.stderr)

    def test_missing_python_is_exit_2(self):
        env = self.env("rows")
        env["PATH"] = os.path.join(self.tmp, "empty-path-ps")
        os.makedirs(env["PATH"], exist_ok=True)
        r = self.launch(["SELECT 1"], env)
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn(b"Python 3 is required (tried py -3, python, python3)", r.stderr)

    def test_temp_file_for_inline_sql_is_removed(self):
        tmpdir = os.path.join(self.tmp, "ps-tmp")
        os.makedirs(tmpdir, exist_ok=True)
        env = self.env("rows", TMPDIR=tmpdir, TMP=tmpdir, TEMP=tmpdir)
        r = self.launch(["SELECT 1"], env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(os.listdir(tmpdir), [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
