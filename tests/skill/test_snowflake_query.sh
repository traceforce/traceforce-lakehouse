#!/usr/bin/env bash
# snowflake_query.sh's PROCEDURE/CALL guard, without an account: a refused query exits 2 with
# "refusing to run"; an allowed one gets past the guard to the connector import, which a stub
# package makes fail with "test stub".
#
#   tests/skill/test_snowflake_query.sh
set -u
SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/skills/traceforce-lakehouse/scripts/snowflake_query.sh"
unset SNOWFLAKE_ORGANIZATION_NAME SNOWFLAKE_ACCOUNT_NAME SNOWFLAKE_USER SNOWFLAKE_AUTHENTICATOR \
  SNOWFLAKE_PRIVATE_KEY
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/pkg/snowflake" "$TMP/crlf"
echo 'raise ImportError("test stub")' > "$TMP/pkg/snowflake/__init__.py"
export PYTHONPATH="$TMP/pkg"
# Windows Python writes CRLF, and $(...) strips only the LF.
cat > "$TMP/crlf/python3" <<EOF
#!/bin/sh
"$(command -v python3)" "\$@" | awk '{ printf "%s\r\n", \$0 }'
EOF
chmod +x "$TMP/crlf/python3"
fails=0

check() { # expect(refused|allowed) description sql
  local out code ok
  out="$("$SCRIPT" "$3" 2>&1 >/dev/null)"; code=$?
  if [[ "$1" == refused ]]; then
    [[ $code -eq 2 && "$out" == *"refusing to run"* ]] && ok=1 || ok=0
  else
    [[ "$out" != *"refusing to run"* && "$out" == *"test stub"* ]] && ok=1 || ok=0
  fi
  if [[ $ok -eq 1 ]]; then echo "ok    $1: $2"; else echo "FAIL  $1: $2 -> exit $code: $out"; fails=$((fails + 1)); fi
}

PROC='WITH p AS PROCEDURE () RETURNS INT LANGUAGE SQL AS $$ BEGIN RETURN 1; END $$ CALL p()'
for path in "$PATH" "$TMP/crlf:$PATH"; do
  label="$([[ "$path" == "$PATH" ]] && echo "" || echo "CRLF python output, ")"
  PATH="$path" check allowed "${label}SELECT"                 "SELECT 1"
  PATH="$path" check allowed "${label}call in a string"       "SELECT 'call' AS s"
  PATH="$path" check refused "${label}WITH ... PROCEDURE"     "$PROC"
  PATH="$path" check refused "${label}CALL"                   "SELECT 1 FROM t WHERE x IN (CALL f())"
  PATH="$path" check refused "${label}not a read"             "DELETE FROM agents"
done

echo
[[ $fails -eq 0 ]] && echo "PASS" || { echo "FAIL ($fails)"; exit 1; }
