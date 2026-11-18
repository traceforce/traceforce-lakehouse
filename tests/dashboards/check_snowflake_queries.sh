#!/usr/bin/env bash
# Live check of the dashboards' Snowflake queries: each runs through snowflake_query.sh (so as the reader
# role), rendered by engines.mjs as serve.mjs renders it, and its CSV header must equal the expected columns
# below (test_engines.mjs checks those against the Athena originals). Queries with parameters run with
# several sample values (a NULL person or agent; 0, 1, 3, 6 and 9 fraction digits in since). A failed query is
# retried once, then reported with its cause. Needs Node 18 or later, python3 with snowflake-connector-python,
# and the script's credentials (see snowflake_query.sh) for a user holding the lakehouse's reader role.
#
#   tests/dashboards/check_snowflake_queries.sh
#
# The script prints no header for an empty result, so each query is wrapped in a LEFT JOIN on one row:
# at least one row comes back, with the query's own column names.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/skills/traceforce-lakehouse/scripts/snowflake_query.sh"
fails=0

render() { # dashboard query json-values: the SQL serve.mjs would send
  node --input-type=module -e '
    const [root, dash, name, values] = process.argv.slice(1);
    const { ENGINES, buildSql } = await import(`${root}/examples/dashboards/engines.mjs`);
    const { params } = await import(`${root}/examples/dashboards/${dash}/api.mjs`);
    const { readFileSync } = await import("node:fs");
    const text = readFileSync(`${root}/examples/dashboards/${dash}/queries/snowflake/${name}.sql`, "utf8");
    process.stdout.write(buildSql(ENGINES.snowflake, text, params, JSON.parse(values), [], name).replace(/^--.*\n/gm, ""));
  ' "$ROOT" "$1" "$2" "$3"
}

cause() { # a failed run's stderr file: the error, without Python warnings or the multi-statement wrapper
  node --input-type=module -e '
    const { scriptMessages, snowflakeError } = await import(`${process.argv[1]}/examples/dashboards/engines.mjs`);
    const lines = scriptMessages((await import("node:fs")).readFileSync(process.argv[2], "utf8"));
    process.stdout.write(lines.length ? snowflakeError(lines) : "(no message)");
  ' "$ROOT" "$1"
}

check() { # dashboard query expected-header [json-values]
  local sql out code values="${4:-}" json="${4:-}"
  [[ -n "$json" ]] || json='{}'
  sql="SELECT q.* FROM (SELECT 1 AS \"one\") d LEFT JOIN ($(render "$1" "$2" "$json")) q ON TRUE"
  local err; err="$(mktemp)"
  out="$("$SCRIPT" "$sql" 2>"$err")"; code=$?
  [[ $code -eq 0 ]] || { out="$("$SCRIPT" "$sql" 2>"$err")"; code=$?; }
  out="${out%%$'\n'*}"
  if [[ $code -eq 0 && "$out" == "$3" ]]; then echo "ok    $1/$2 $values"
  else
    echo "FAIL  $1/$2 $values -> exit $code, header: $out (want: $3)"; fails=$((fails + 1))
    [[ $code -eq 0 ]] || echo "      $(cause "$err")"
  fi
  rm -f "$err"
}

U=usage-and-spend
SESSION="agent,person,session_id,device_native_id,started_at,ended_at,models,prompts,tool_calls,input_tokens,output_tokens,cost_usd"
check "$U" freshness "ingested_through,events_through"
check "$U" models "day,agent,model,requests,input_tokens,output_tokens,cache_read_tokens,cost_usd"
check "$U" activity "day,agent,person,sessions,prompts,tool_calls,input_tokens,output_tokens,cache_read_tokens,cost_usd"
check "$U" unattributed "day,agent,device_native_id,sessions,tool_calls,tokens,cost_usd"
check "$U" unattributed_devices "device_native_id,live_devices,device_names,platforms,last_seen_at,mdm_status,accounts"
for person in '"jane.doe@example.com"' '""'; do
  check "$U" sessions "$SESSION" "{\"person\":$person}"
  check "$U" tools "day,agent,person,tool,calls" "{\"person\":$person}"
done
for since in "2026-01-01 00:00:00" "2026-01-01 00:00:00.5" "2026-01-01 00:00:00.123" "2026-01-01 00:00:00.123456" "2026-01-01 00:00:00.123456789"; do
  check "$U" recent_sessions "$SESSION" "{\"agent\":\"\",\"since\":\"$since\"}"
done
check "$U" recent_sessions "$SESSION" '{"agent":"claude_code","since":"2026-01-01 00:00:00"}'
PROMPTS="agent,person,session_id,ts,ended_at,prompt,response,models,tool_calls,input_tokens,output_tokens,cost_usd"
for person in '"jane.doe@example.com"' '""'; do
  check "$U" prompts "$PROMPTS" "{\"agent\":\"claude_code\",\"person\":$person,\"session_id\":\"s-1\",\"since\":\"2026-01-01 00:00:00.123\"}"
done

I=incident-triage
check "$I" freshness "findings_through,events_through"
check "$I" findings "id,kind,at,day,status,category,type,type_name,outcome,detail,message_external_id,tool_use_id,criticality,person,agent,session_id,session_name,device"
check "$I" blocks "at,day,agent,person,session_id,blocked,detail,tool_args"
for person in '"jane.doe@example.com"' '""'; do
  check "$I" timeline "ts,kind,tool,tool_call_id,text,decision,decision_source,error_type,message_id" \
    "{\"session_id\":\"s-1\",\"person\":$person,\"since\":\"2026-01-01 00:00:00\",\"until\":\"2026-12-31 23:59:59.999999\"}"
done

[[ $fails -eq 0 ]] && echo "all passed" || { echo "$fails failed"; exit 1; }
