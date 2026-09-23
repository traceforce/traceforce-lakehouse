#!/usr/bin/env bash
# Run one read-only SQL statement against the TraceForce lakehouse on BigQuery (GCP) and
# print the result as CSV. Needs the gcloud CLI signed in (gcloud auth login / ADC) for the
# project that holds the lakehouse dataset. GoogleSQL dialect (see SKILL.md "GCP (BigQuery)").
#
#   TRACEFORCE_LAKEHOUSE_PROJECT=my-proj bq_query.sh "SELECT count(*) FROM traceforce_lakehouse.agent_events"
#   TRACEFORCE_LAKEHOUSE_PROJECT=my-proj bq_query.sh -f query.sql
#
# Env: TRACEFORCE_LAKEHOUSE_PROJECT (optional) the GCP project holding the dataset; defaults
#      to the gcloud config project (`gcloud config set project <id>`) when unset.
#      TRACEFORCE_LAKEHOUSE_MAX_ROWS (default 200); TRACEFORCE_LAKEHOUSE_MAX_GB per-query
#      scan cap (default 50; the query fails rather than scan more).
# Output: CSV on stdout; exit 1 with BigQuery's reason on failure.
set -euo pipefail

PROJECT="${TRACEFORCE_LAKEHOUSE_PROJECT:-}"
MAX_ROWS="${TRACEFORCE_LAKEHOUSE_MAX_ROWS:-200}"
MAX_GB="${TRACEFORCE_LAKEHOUSE_MAX_GB:-50}"

# Default to the gcloud CLI's configured project when the env override is unset, so a customer
# who ran `gcloud config set project <id>` doesn't have to repeat it here. (get-value prints
# "(unset)" when no project is configured.)
if [[ -z "$PROJECT" ]]; then
  PROJECT="$(gcloud config get-value project 2>/dev/null)"
fi
if [[ -z "$PROJECT" || "$PROJECT" == "(unset)" ]]; then
  echo "no GCP project: set TRACEFORCE_LAKEHOUSE_PROJECT or run 'gcloud config set project <id>'" >&2
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

# First-keyword allowlist: a fast fail for an obvious DML/DDL statement. This is a convenience,
# NOT the read-only guarantee -- see the note after the case block.
FIRST="$(printf '%s\n' "$SQL" | grep -vE '^[[:space:]]*(--|$)' | awk '{print toupper($1); exit}')"
case "$FIRST" in
  SELECT|WITH|SHOW|DESCRIBE|DESC|EXPLAIN) ;;
  *) echo "refusing to run a non-read statement (first keyword: $FIRST)" >&2; exit 2 ;;
esac
# Read-only is enforced by IAM, not by this script. Unlike Athena's single-statement API,
# `bq query` runs multi-statement scripts, so `SELECT 1; DELETE ...` would execute the DELETE if
# the caller can write. Run as an identity holding only bigquery.dataViewer (+ jobUser) -- see
# SKILL.md "GCP (BigQuery)". We deliberately do NOT scan for ';': legit reads on this data carry
# ';' in string literals (e.g. searching agent shell commands), so a scan would false-reject them.

bq query --project_id="$PROJECT" --use_legacy_sql=false --format=csv \
  --maximum_bytes_billed="$(( MAX_GB * 1073741824 ))" --max_rows="$MAX_ROWS" "$SQL"
