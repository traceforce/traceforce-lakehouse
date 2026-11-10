"""Write the golden fixture's input files: python3 make_fixture.py fixture
Raw JSON text is written as-is (number spellings, whitespace and escapes matter), so every
document is a hand-written string. Fixed OTLP times are in 2020, far from any run date."""
import json
import os
import sys

OUT = sys.argv[1]
ORG = "0b5c1f6e-1d2a-4c3b-9e8f-7a6b5c4d3e2f"
ACCT = f"dev@example.com_{ORG}"


def w(rel, text):
    p = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def kv(k, v):
    return '{"key":%s,"value":%s}' % (k, v)


S = lambda s: '{"stringValue":"%s"}' % s

# ---- 1. Claude Code logs, today: every AnyValue edge case on one record ----------------------
edge = ",".join([
    kv('"event.name"', S("user_prompt")),
    kv('"user.email"', S("dev@example.com")),
    kv('"organization.id"', S(ORG)),
    kv('"user.id"', S("u-1")),
    kv('"session.id"', S("attr-session")),
    kv('"prompt.id"', S("p-1")),
    kv('"gen_ai.request.model"', S("claude-x")),
    kv('"gen_ai.operation.name"', S("chat")),
    # intValue: string and number forms, above 2^53 in both, exponent form
    kv('"i_str"', '{"intValue":"123"}'),
    kv('"i_num"', '{"intValue":123}'),
    kv('"i_big_str"', '{"intValue":"9007199254740993"}'),
    kv('"i_big_num"', '{"intValue":9007199254740993}'),
    kv('"i_exp"', '{"intValue":1e2}'),
    # doubleValue spellings
    kv('"d_1_0"', '{"doubleValue":1.0}'),
    kv('"d_1"', '{"doubleValue":1}'),
    kv('"d_1_5"', '{"doubleValue":1.5}'),
    kv('"d_1_50"', '{"doubleValue":1.50}'),
    kv('"d_1e20"', '{"doubleValue":1e20}'),
    kv('"d_12345678_9"', '{"doubleValue":12345678.9}'),
    kv('"d_0_0001"', '{"doubleValue":0.0001}'),
    kv('"d_nan"', '{"doubleValue":"NaN"}'),
    kv('"d_inf"', '{"doubleValue":"Infinity"}'),
    kv('"d_str"', '{"doubleValue":"1.5"}'),
    kv('"b_true"', '{"boolValue":true}'),
    kv('"b_false"', '{"boolValue":false}'),
    # bytes, empty AnyValue, explicit null string: key kept, value null
    kv('"v_bytes"', '{"bytesValue":"AQID"}'),
    kv('"v_empty"', '{}'),
    kv('"v_null"', '{"stringValue":null}'),
    # JSON paths are case-sensitive on AWS: IntValue is not intValue
    kv('"v_wrong_case"', '{"IntValue":"5"}'),
    # arrays: arrayValue:{}, empty values, mixed with a nested kvlist (whitespace + 1.50 inside)
    kv('"a_empty"', '{"arrayValue":{}}'),
    kv('"a_empty_values"', '{"arrayValue":{"values":[]}}'),
    kv('"a_mixed"', '{"arrayValue":{"values":[{"stringValue":"a"}, {"intValue":"5"},{"doubleValue":1.50},'
                    '{"kvlistValue":{"values":[{"key":"y","value":{"boolValue":true}},{"key":"x","value":{"stringValue":"v"}}]}}]}}'),
    # kvlists: empty, and keys out of order with a duplicate, nested kvlist, nested bytes, odd spacing
    kv('"kv_empty"', '{"kvlistValue":{}}'),
    kv('"kv_mixed"', '{"kvlistValue":{"values":['
                     '{"key":"z","value":{"doubleValue": 1.50}},'
                     '{"key":"10","value":{"intValue":"10"}},'
                     '{"key":"a","value":{"stringValue":"first"}},'
                     '{"key":"b","value":{"kvlistValue":{"values":[{"key":"q","value":{ "intValue" : 7 }},{"key":"p","value":{"doubleValue":2.50}}]}}},'
                     '{"key":"a","value":{"stringValue":"second"}},'
                     '{"key":"n","value":{"bytesValue":"AQID"}},'
                     '{"key":"e","value":{}},'
                     '{"key":"arr","value":{"arrayValue":{"values":[{"intValue":"1"}]}}}'
                     ']}}'),
    # duplicate top-level keys (first wins), empty-string key, keys differing only in case
    kv('"dup"', S("first")),
    kv('"dup"', S("second")),
    kv('""', S("empty-key")),
    kv('"Case"', S("upper")),
    kv('"case"', S("lower")),
    # escapes and non-ASCII
    kv('"s_special"', '{"stringValue":"q\\"uote back\\\\slash sl/ash \\u00e9 é \\ud83d\\ude00 \U0001F600 nl\\n esc\\u001b"}'),
    # tokens: input as a double (42.0), output as an int string, cache_read via the gen_ai key
    kv('"gen_ai.usage.input_tokens"', '{"doubleValue":42.0}'),
    kv('"gen_ai.usage.output_tokens"', '{"intValue":"17"}'),
    kv('"gen_ai.usage.cache_read.input_tokens"', '{"intValue":"9223372036854775808"}'),
    kv('"cost_usd"', '{"doubleValue":0.25}'),
    # the four content keys: own columns, left out of attrs_json
    kv('"gen_ai.input.messages"', S('[{\\"role\\":\\"user\\"}]')),
    kv('"gen_ai.output.messages"', S("out")),
    kv('"gen_ai.tool.call.result"', S("result")),
])
res = ",".join([
    kv('"traceforce.device.native_id"', S("RES-SERIAL")),
    kv('"traceforce.device.uuid"', S("dev-uuid-1")),
    kv('"service.name"', S("claude-code")),
    kv('"service.version"', S("2.0.1")),
    kv('"os.type"', S("darwin")),
    kv('"session.id"', S("res-session")),
    kv('"service.name"', S("duplicate-loses")),
    kv('"r_kv"', '{"kvlistValue":{"values":[{"key":"b","value":{"intValue":2}},{"key":"a","value":{"intValue":"1"}}]}}'),
    kv('"r_arr"', '{"arrayValue":{"values":[{"stringValue":"x"}]}}'),
])
tool_args = ('{"kvlistValue":{"values":['
             '{"key":"query","value":{"stringValue":"select 1"}},'
             '{"key":"mcp_server_name","value":{"stringValue":"github"}},'
             '{"key":"limit","value":{"intValue":"10"}}]}}')
recs = ",".join([
    # sub-microsecond nanos: 600 rounds up to the next microsecond on AWS
    '{"timeUnixNano":"1577975587725000600","observedTimeUnixNano":"1577975587800000000",'
    '"body":{"stringValue":""},"attributes":[%s]}' % edge,
    # time 0 = unknown: falls back to observed time; tool call with kvlist arguments
    '{"timeUnixNano":"0","observedTimeUnixNano":"1577975590000000499","attributes":[%s]}' % ",".join([
        kv('"event.name"', S("tool_result")),
        kv('"gen_ai.tool.name"', S("mcp__github__search")),
        kv('"gen_ai.tool.type"', S("mcp")),
        kv('"gen_ai.tool.call.id"', S("call-1")),
        kv('"gen_ai.tool.call.arguments"', tool_args),
        kv('"decision"', S("allow")),
        kv('"error_type"', S("timeout")),
        kv('"traceforce.sd_enforcement"', S("warn")),
        kv('"traceforce.containment_enforcement"', S("block")),
        kv('"gen_ai.conversation.id"', S("conv-1")),
    ]),
    # no time at all: ts = upload time from the filename
    '{"attributes":[%s]}' % kv('"event.name"', S("no_time")),
    # MCP connection event: server under the bare key
    '{"timeUnixNano":"1577975591000000000","attributes":[%s]}' % ",".join([
        kv('"event.name"', S("mcp_server_connection")),
        kv('"server_name"', S("linear")),
        kv('"hook.result.permission"', S("deny")),
    ]),
])
logs = ('{"resourceLogs":[{"resource":{"attributes":[%s]},"scopeLogs":[{"scope":{"name":"s"},"logRecords":[%s]}]}]}'
        % (res, recs))
w(f"raw/telemetry/agent=AGENT_IDENTITY_CLAUDE_CODE/dt=@D0@/SERIAL-1/{ACCT}/sess-1/"
  f"@D0@_120000.123_11111111-1111-4111-8111-111111111111_logs.json", logs)

# ---- 2. Cursor spans, yesterday: span name, start/end, tool args as a JSON string, input tokens
# as an int, a generation id ------------------------------------------------------------------
spans = ('{"resourceSpans":[{"resource":{"attributes":[%s]},"scopeSpans":[{"scope":{"name":"s"},"spans":[%s]}]}]}'
         % (",".join([kv('"service.name"', S("cursor")), kv('"traceforce.sandbox.native_id"', S("sbx-1"))]),
            '{"name":"tool.call","startTimeUnixNano":"1577889187000000000","endTimeUnixNano":"1577889188500000000",'
            '"attributes":[%s]}' % ",".join([
                kv('"gen_ai.tool.name"', S("read_file")),
                kv('"tool_parameters"', S('{\\"mcp_server_name\\":\\"fs\\",\\"path\\":\\"/tmp\\"}')),
                kv('"github.copilot.permission.result"', S("approved")),
                kv('"error.type"', S("none")),
                kv('"cache_read_tokens"', '{"intValue":"5"}'),
                kv('"gen_ai.usage.input_tokens"', '{"intValue":"1234"}'),
                kv('"generation.id"', S("gen-1")),
                kv('"cost_usd"', S("not-a-number")),
            ])))
w(f"raw/telemetry/agent=AGENT_IDENTITY_CURSOR/dt=@D-1@/SERIAL-2/unknown-account/unknown-session/"
  f"@D-1@_235959.999_22222222-2222-4222-8222-222222222222_traces.json", spans)

# ---- 3. Edges of the window ------------------------------------------------------------------
small = lambda ev: ('{"resourceLogs":[{"resource":{"attributes":[]},"scopeLogs":[{"logRecords":['
                    '{"timeUnixNano":"1577975600000000000","attributes":[%s]}]}]}]}' % kv('"event.name"', S(ev)))
# tomorrow (a fast device clock): read; '+' and a space in the path
w(f"raw/telemetry/agent=AGENT_IDENTITY_CLAUDE_CODE/dt=@D+1@/SERIAL-1/dev+tag@example.com/sess 2/"
  f"@D+1@_000001.000_33333333-3333-4333-8333-333333333333_logs.json", small("tomorrow"))
# the day after tomorrow, just beyond the window: never read
w(f"raw/telemetry/agent=AGENT_IDENTITY_CLAUDE_CODE/dt=@D+2@/SERIAL-1/dev@example.com/sess-3/"
  f"@D+2@_000001.000_88888888-8888-4888-8888-888888888888_logs.json", small("beyond_tomorrow"))
# five days ahead: never read
w(f"raw/telemetry/agent=AGENT_IDENTITY_CLAUDE_CODE/dt=@D+5@/SERIAL-1/dev@example.com/sess-3/"
  f"@D+5@_000001.000_44444444-4444-4444-8444-444444444444_logs.json", small("future"))
# oldest day in a 3-day window: read; one day older: not read. An email may contain '=' (which
# read_files() partition discovery would mistake for a partition folder)
w(f"raw/telemetry/agent=AGENT_IDENTITY_GITHUB_COPILOT/dt=@D-2@/SERIAL-3/a=b@example.com/sess-4/"
  f"@D-2@_080000.000_55555555-5555-4555-8555-555555555555_logs.json", small("window_start"))
w(f"raw/telemetry/agent=AGENT_IDENTITY_GITHUB_COPILOT/dt=@D-3@/SERIAL-3/dev@example.com/sess-5/"
  f"@D-3@_080000.000_66666666-6666-4666-8666-666666666666_logs.json", small("too_old"))
# not JSON: no rows, and the run must not fail
w(f"raw/telemetry/agent=AGENT_IDENTITY_GITHUB_COPILOT/dt=@D0@/SERIAL-3/dev@example.com/sess-6/"
  f"@D0@_090000.000_77777777-7777-4777-8777-777777777777_logs.txt", "this is not json\n")

# ---- 4. Mirror snapshots: agents (string, int, double, boolean, timestamp) --------------------
AG = ["id", "org_id", "agent_catalog_id", "agent_type", "plan", "active_users", "total_incidents",
      "active_issues", "affected_devices", "base_score", "actual_score", "deployment_types",
      "sandbox_runtime_types", "instance_count", "has_host_instances", "first_seen_at",
      "last_active_at", "last_reviewed", "created_at", "updated_at", "deleted_at"]


def row(**v):
    base = {c: None for c in AG}
    base.update(org_id=ORG, agent_type="claude_code")
    raws = v.pop("_raw", {})
    base.update(v)
    # JSON numbers/booleans as the export writes them; raw spellings via a placeholder swap
    s = json.dumps(base, ensure_ascii=False, separators=(",", ":"))
    for k, raw in raws.items():
        s = s.replace('"%s":"__RAW__"' % k, '"%s":%s' % (k, raw))
    return s


def agents_row(id, plan, **extra):
    return row(id=id, plan=plan, **extra)


day1 = "\n".join([
    agents_row("a1", "free", active_users=3, base_score=1.5, has_host_instances=True,
               created_at="2026-10-01T10:00:00+00:00"),
    agents_row("a2", "team", active_users=1, created_at="2026-10-02T10:00:00Z"),
    agents_row("a3", "team", created_at="2026-10-03T10:00:00+00:00"),
]) + "\n"
day2 = "\n".join([
    # a1 renamed (plan changed); offsets applied, not dropped; odd numeric spellings
    row(id="a1", plan="enterprise", active_users="__RAW__", total_incidents="abc",
        active_issues="__RAW__", base_score="__RAW__", actual_score="__RAW__",
        has_host_instances=False, created_at="2026-10-01T15:30:00+05:30",
        updated_at="2026-10-30T23:59:59.123456-07:00", last_reviewed="2026-10-30 08:00:00",
        first_seen_at="not a time",
        _raw={"active_users": "7", "active_issues": "99999999999", "base_score": "1.50",
              "actual_score": "1e20"}),
    # the other two forms Postgres writes for a contract timestamp: a date (midnight UTC) and a
    # timestamp without time zone (read as UTC)
    agents_row("a2", "team", active_users=1, created_at="2026-10-02T10:00:00Z",
               last_active_at="2026-10-29", first_seen_at="2026-10-28T07:08:09.5"),
    # a3 deleted at TraceForce; a4 added
    agents_row("a4", "free", instance_count=2, deployment_types='["host","sandbox"]',
               created_at="2026-10-30T01:02:03.000001+00:00"),
    # a row without id is skipped
    agents_row(None, "orphan"),
]) + "\n"
w("exports/agents/dt=@D-1-@/110000.jsonl", day1)
# day 2 is laid out after the mirror has run on day 1, so the MERGE updates a1, deletes a3 and
# inserts a4 (golden.lay_out phase 2)
w("exports_day2/agents/dt=@D0-@/110000.jsonl", day2)
# future-dated snapshot: never the newest
w("exports/agents/dt=@D+1-@/110000.jsonl", agents_row("future", "free") + "\n")
# phase 3 only: a broken newest snapshot (rows, but none with an id) must delete nothing
w("exports_phase2/agents/dt=@D0-@/130000.jsonl", agents_row(None, "broken") + "\n")
# phase 4 only: a malformed newest snapshot must fail the mirror run (FAILFAST, the error re-raised)
# and change nothing
w("exports_phase4/agents/dt=@D0-@/140000.jsonl", "not json\n")

# ---- 5. Mirror snapshot: agent_conversation_files (long, which agents lacks) ------------------
# One snapshot, mirrored at every step: size_bytes spellings as JSON numbers and strings. Dated
# D-7, the oldest day of the mirror's 7-day window, so it must be read.
files = []
for i, size in enumerate(["3000000000", "9223372036854775807", "9223372036854775808", "-1", "1.5",
                          "1e3", '"42"', '"abc"', "null"], 1):
    s = json.dumps({"id": f"f{i}", "org_id": ORG, "file_name": f"file {i}", "size_bytes": "__RAW__",
                    "created_at": "2026-10-01T10:00:00+00:00"}, separators=(",", ":"))
    files.append(s.replace('"size_bytes":"__RAW__"', f'"size_bytes":{size}'))
w("exports/agent_conversation_files/dt=@D-7-@/110000.jsonl", "\n".join(files) + "\n")

# ---- 6. Mirror snapshot: issue_type_controls, only beyond the window -------------------------
# Its only snapshot is one day older than the window (D-8): never read, so its mirror stays empty.
w("exports/issue_type_controls/dt=@D-8-@/110000.jsonl",
  json.dumps({"id": "c1", "org_id": ORG, "issue_type_id": "t1",
              "created_at": "2026-10-01T10:00:00+00:00"}, separators=(",", ":")) + "\n")
print("ok")
