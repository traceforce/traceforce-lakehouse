#!/usr/bin/env bash
# Run one read-only SQL statement against the TraceForce lakehouse through Snowflake and print
# the result as CSV. Needs python3 with snowflake-connector-python installed; the work is done
# by snowflake_query.py next to this script (snowflake_query.ps1 is the Windows twin).
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
# failure reason on stderr when the query fails, exit 2 for a usage error or a refused query.
#
# Read-only model: every query runs as traceforce_lakehouse_reader with SECONDARY ROLES NONE, as
# a single SELECT/WITH/SHOW/DESCRIBE/EXPLAIN statement; stored-procedure calls, Scripting blocks
# and the ->> operator are refused (details in snowflake_query.py).
set -euo pipefail

command -v python3 >/dev/null 2>&1 || { echo "python3 is required (see the header)" >&2; exit 2; }
SNOWFLAKE_QUERY_PROG="${0##*/}" exec python3 "$(cd "$(dirname "$0")" && pwd)/snowflake_query.py" "$@"
