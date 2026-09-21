#!/usr/bin/env bash
# Run one read-only SQL statement against the TraceForce lakehouse on BigQuery (GCP) and
# print the result as CSV. Needs the gcloud CLI signed in (gcloud auth login / ADC) for the
# project that holds the lakehouse dataset. GoogleSQL dialect (see SKILL.md "GCP (BigQuery)").
#
#   TRACEFORCE_LAKEHOUSE_PROJECT=my-proj bq_query.sh "SELECT count(*) FROM traceforce_lakehouse.agent_events"
#   TRACEFORCE_LAKEHOUSE_PROJECT=my-proj bq_query.sh -f query.sql
#
# Env: TRACEFORCE_LAKEHOUSE_PROJECT (required) the GCP project holding the dataset;
#      TRACEFORCE_LAKEHOUSE_MAX_ROWS (default 200); TRACEFORCE_LAKEHOUSE_MAX_GB per-query
#      scan cap (default 50; the query fails rather than scan more).
# Output: CSV on stdout; exit 1 with BigQuery's reason on failure.
set -euo pipefail

PROJECT="${TRACEFORCE_LAKEHOUSE_PROJECT:-}"
MAX_ROWS="${TRACEFORCE_LAKEHOUSE_MAX_ROWS:-200}"
MAX_GB="${TRACEFORCE_LAKEHOUSE_MAX_GB:-50}"

if [[ -z "$PROJECT" ]]; then
  echo "set TRACEFORCE_LAKEHOUSE_PROJECT to the GCP project holding the lakehouse dataset" >&2
  exit 2
fi
if [[ "${1:-}" == "-f" ]]; then
  SQL="$(cat "$2")"
else
  SQL="${1:-}"
fi
if [[ -z "$SQL" ]]; then
  echo "usage: $0 \"SQL\" | -f file.sql" >&2
  exit 2
fi

# Read-only by construction (the query identity should hold only dataViewer + jobUser); this
# fails faster and blocks a stray DML/DDL first keyword.
FIRST="$(printf '%s\n' "$SQL" | grep -vE '^[[:space:]]*(--|$)' | awk '{print toupper($1); exit}')"
case "$FIRST" in
  SELECT|WITH|SHOW|DESCRIBE|DESC|EXPLAIN) ;;
  *) echo "refusing to run a non-read statement (first keyword: $FIRST)" >&2; exit 2 ;;
esac
# Block multi-statement scripting (bq runs scripts, unlike Athena): drop trailing whitespace
# and one optional trailing ';', then reject if any ';' remains (a per-line sed anchor missed a
# ';' split across newlines).
BODY="${SQL%"${SQL##*[![:space:]]}"}" # rstrip
BODY="${BODY%;}"                      # drop one trailing ';'
if [[ "$BODY" == *";"* ]]; then
  echo "refusing multi-statement SQL (a ';' before the end of the statement)" >&2
  exit 2
fi

bq query --project_id="$PROJECT" --use_legacy_sql=false --format=csv \
  --maximum_bytes_billed="$(( MAX_GB * 1073741824 ))" --max_rows="$MAX_ROWS" "$SQL"
