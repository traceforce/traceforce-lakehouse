#!/usr/bin/env bash
# databricks_query.sh's read-only checks, without a workspace: a refused query exits 2 with
# "refusing to run" before any network call; an allowed one gets past the checks and fails to
# reach the (invalid) host instead.
#
#   tests/skill/test_databricks_query.sh
set -u
SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/skills/traceforce-lakehouse/scripts/databricks_query.sh"
export DATABRICKS_HOST="workspace.invalid" TRACEFORCE_LAKEHOUSE_WAREHOUSE_ID="0000"
export DATABRICKS_CLIENT_ID="test" DATABRICKS_CLIENT_SECRET="test"   # no az call; the token request fails
fails=0

check() { # expect(refused|allowed) description sql
  local out code
  out="$("$SCRIPT" "$3" 2>&1 >/dev/null)"; code=$?
  if [[ "$1" == refused ]]; then
    [[ $code -eq 2 && "$out" == *"refusing to run"* ]] && ok=1 || ok=0
  else
    [[ "$out" != *"refusing to run"* && "$out" == *"cannot reach"* ]] && ok=1 || ok=0
  fi
  if [[ $ok -eq 1 ]]; then echo "ok    $1: $2"; else echo "FAIL  $1: $2 -> exit $code: $out"; fails=$((fails + 1)); fi
}

check_word() { # write keyword: refused, and named in the message
  local out code
  out="$("$SCRIPT" "SELECT 1 AS a FROM t WHERE $1" 2>&1 >/dev/null)"; code=$?
  if [[ $code -eq 2 && "$out" == *"the statement contains $1,"* ]]; then echo "ok    refused: $1 after SELECT"
  else echo "FAIL  refused: $1 after SELECT -> exit $code: $out"; fails=$((fails + 1)); fi
}

check allowed "SELECT"                      "SELECT count(*) FROM agent_events"
check allowed "WITH"                        "WITH t AS (SELECT 1 AS x) SELECT x FROM t"
check allowed "SHOW TABLES"                 "SHOW TABLES"
check allowed "DESCRIBE"                    "DESCRIBE agent_events"
check allowed "EXPLAIN"                     "EXPLAIN SELECT 1"
check allowed "leading comment"             "/* note */ -- more
SELECT 1"
check allowed "write word in a string"      "SELECT 'DELETE FROM x' AS s"
check allowed "write word, double-quoted"   "SELECT \"insert\" AS s"
check allowed "write word, backtick-quoted" "SELECT \`update\` FROM t"
check allowed "write word in a comment"     "SELECT 1 -- then DROP TABLE x"
check allowed "updated_at (not a keyword)"  "SELECT updated_at, deleted_at FROM agents"
check allowed "write word in a nested comment" "/* a /* b */ DROP */ SELECT 1"
check allowed "raw string keeps its backslash" "SELECT r'a\\' AS x, 'b DROP' AS y"
check allowed "escaped quote stays in the string" "SELECT 'it\\'s DROP' AS s"
check allowed "/*+ in a string"             "SELECT '/*+ x */' AS s"
check allowed "/*+ in a comment"            "SELECT 1 /* a /*+ b */ */"
check allowed "trailing ;"                  "SELECT 1;"
check allowed "comments after the ;"        "SELECT 1; -- done
/* really */"
check allowed "; in a string"               "SELECT ';' AS s, 1 AS x"
check allowed "backslash inside a comment"  "SELECT 1 -- C:\\x\\y
FROM t"
check refused "INSERT"                      "INSERT INTO agent_events SELECT * FROM agent_events"
check refused "lowercase delete"            "delete from agents"
check refused "BEGIN ... END"               "BEGIN SELECT 1; DELETE FROM agents; END"
check refused "EXECUTE IMMEDIATE"           "EXECUTE IMMEDIATE 'DROP TABLE agents'"
check refused "CALL"                        "CALL system.something()"
check refused "write behind WITH"           "WITH t AS (SELECT 1) INSERT INTO agents SELECT * FROM t"
check refused "SELECT then CALL"            "SELECT 1 FROM t WHERE x IN (CALL f())"
check refused "comment hides the start"     "/* SELECT */ DROP TABLE agents"
check refused "nested comment"              "/* a /* b */ SELECT */ DROP TABLE agents"
check refused "escaped quote in a string"   "SELECT 'it\\'s' FROM t; DELETE FROM agents"
check refused "raw string ends at the quote" "SELECT r'\\' AS a, 1 FROM t WHERE 1 = 1 UNION SELECT 1 FROM (MERGE INTO x USING y ON true WHEN MATCHED THEN DELETE)"
check refused "comment continued by a backslash" "-- \\
SELECT '
DELETE FROM agents -- '"
check refused "continued comment hides DROP" "SELECT 1 AS x -- \\
, ' AS y
DROP TABLE agents -- '"
check refused "hint hides a write"          "WITH a AS (SELECT /*+ foo('/*') */ 1) INSERT INTO agents SELECT * FROM a -- */"
check refused "any hint"                    "SELECT /*+ BROADCAST(t) */ 1 FROM t"
check refused "a second statement"          "SELECT 1; USE other_catalog"
check refused "; then RESTORE"              "SELECT 1; RESTORE TABLE agents TO VERSION AS OF 0"
# Every write keyword on its own, after a read first keyword: dropping any from the script's list
# fails its case.
for w in INSERT UPDATE DELETE MERGE CREATE DROP ALTER TRUNCATE GRANT REVOKE COPY CALL EXECUTE \
         OVERWRITE REFRESH OPTIMIZE VACUUM; do
  check_word "$w"
done
check refused "no keyword"                  "-- nothing here"
check refused "Unicode line separator"      "SELECT 1 -- note$(printf ' ')DROP TABLE agents"

TRACEFORCE_LAKEHOUSE_CATALOG=my_catalog check allowed "custom catalog" "SELECT 1"
out="$(TRACEFORCE_LAKEHOUSE_CATALOG='x`; DROP' "$SCRIPT" "SELECT 1" 2>&1 >/dev/null)"; code=$?
if [[ $code -eq 2 && "$out" == *"invalid TRACEFORCE_LAKEHOUSE_CATALOG"* ]]; then echo "ok    refused: catalog not an identifier"
else echo "FAIL  refused: catalog not an identifier -> exit $code: $out"; fails=$((fails + 1)); fi

# A python3 that only prints a hint (Windows' Store stub): the script falls back to python.
STUB="$(mktemp -d)"; trap 'rm -rf "$STUB"' EXIT
printf '#!/bin/sh\necho "Python was not found" >&2; exit 49\n' > "$STUB/python3"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$(command -v python3)" > "$STUB/python"
chmod +x "$STUB/python3" "$STUB/python"
PATH="$STUB:$PATH" check allowed "python3 stub, falls back to python" "SELECT 1"
PATH="$STUB:$PATH" check refused "python3 stub, scan still runs"      "DELETE FROM agents"

# Windows Python writes CRLF: the scan's trailing \r must not refuse every query.
CRLF="$(mktemp -d)"; trap 'rm -rf "$STUB" "$CRLF"' EXIT
cat > "$CRLF/python3" <<EOF
#!/bin/sh
"$(command -v python3)" "\$@" | awk '{ printf "%s\r\n", \$0 }'
EOF
chmod +x "$CRLF/python3"
PATH="$CRLF:$PATH" check allowed "CRLF python output, SELECT"         "SELECT 1"
PATH="$CRLF:$PATH" check refused "CRLF python output, CALL"           "SELECT 1 FROM t WHERE x IN (CALL f())"

echo
[[ $fails -eq 0 ]] && echo "PASS" || { echo "FAIL ($fails)"; exit 1; }
