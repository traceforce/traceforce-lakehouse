#!/usr/bin/env bash
# Run one SQL statement against the TraceForce lakehouse through Athena and print the
# result as CSV. Needs the AWS CLI v2 with credentials that carry the module's
# query_policy_json policy (or broader).
#
#   athena_query.sh "SELECT count(*) FROM agent_events"
#   athena_query.sh -f query.sql
#   AWS_PROFILE=customer AWS_REGION=us-east-1 athena_query.sh "..."
#
# Names are fixed by the module (workgroup traceforce-lakehouse, catalog
# s3tablescatalog/traceforce-lakehouse, namespace traceforce). Optional:
#   TRACEFORCE_LAKEHOUSE_MAX_ROWS   rows to print (default 200; 0 = all)
#
# Output: CSV on stdout; "-- query <id> ok, scanned N MB" and any truncation note on stderr;
# exit 1 with Athena's failure reason when the query fails.
set -euo pipefail

WG="traceforce-lakehouse"
CATALOG="s3tablescatalog/traceforce-lakehouse"
NS="traceforce"
MAX_ROWS="${TRACEFORCE_LAKEHOUSE_MAX_ROWS:-200}"

if [[ "${1:-}" == "-f" ]]; then
  SQL="$(cat "$2")"
else
  SQL="${1:-}"
fi
if [[ -z "$SQL" ]]; then
  echo "usage: $0 \"SQL\" | -f file.sql" >&2
  exit 2
fi
# Read-only by construction: the policy forbids writes anyway, this just fails faster.
FIRST="$(printf '%s\n' "$SQL" | grep -vE '^[[:space:]]*(--|$)' | awk '{print toupper($1); exit}')"
case "$FIRST" in
  SELECT|WITH|SHOW|DESCRIBE|DESC|EXPLAIN) ;;
  *) echo "refusing to run a non-read statement (first keyword: $FIRST)" >&2; exit 2 ;;
esac

# The workgroup pins the result location and encryption, so none is passed here.
QID="$(aws athena start-query-execution \
  --work-group "$WG" \
  --query-execution-context "Catalog=$CATALOG,Database=$NS" \
  --query-string "$SQL" \
  --query QueryExecutionId --output text)"
# Ctrl-C or a tool timeout cancels the scan instead of leaving it running.
trap 'aws athena stop-query-execution --query-execution-id "$QID" >/dev/null 2>&1 || true' INT TERM

while :; do
  # A transient CLI failure (throttle, expired token) must not kill the poll loop.
  if ! LINE="$(aws athena get-query-execution --query-execution-id "$QID" \
      --query '[QueryExecution.Status.State, QueryExecution.Status.StateChangeReason, QueryExecution.ResultConfiguration.OutputLocation]' \
      --output text)"; then
    sleep 2
    continue
  fi
  IFS=$'\t' read -r STATE REASON OUT <<<"$LINE"
  case "$STATE" in
    SUCCEEDED) break ;;
    FAILED|CANCELLED) echo "Athena $STATE ($QID): $REASON" >&2; exit 1 ;;
    *) sleep 1 ;;
  esac
done
trap - INT TERM

SCANNED="$(aws athena get-query-execution --query-execution-id "$QID" \
  --query 'QueryExecution.Statistics.DataScannedInBytes' --output text)"
echo "-- query $QID ok, scanned $((SCANNED / 1048576)) MB" >&2

# Download to a file first: piping into head would kill the download mid-stream on large
# results and turn a successful query into a broken-pipe failure.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
aws s3 cp --only-show-errors "$OUT" "$TMP"
if [[ "$MAX_ROWS" == "0" ]]; then
  cat "$TMP"
  exit 0
fi
TOTAL=$(( $(wc -l < "$TMP") - 1 ))
head -n "$((MAX_ROWS + 1))" "$TMP"
if (( TOTAL > MAX_ROWS )); then
  echo "-- showing $MAX_ROWS of $TOTAL result lines; set TRACEFORCE_LAKEHOUSE_MAX_ROWS=0 for all (lines, not rows: quoted content can span lines)" >&2
fi
