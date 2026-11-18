// The dashboards' token relay (terraform/snowflake/relay/relay.mjs, run by the AWS Lambda and the
// Azure Function), offline with a stubbed fetch:
//
//   node tests/terraform/test_dashboard_relay.mjs
//
// Needs Node 18 or later.
import { test } from "node:test"
import assert from "node:assert/strict"
import { relay, lowerHeaders } from "../../terraform/snowflake/relay/relay.mjs"

const ORIGIN = "https://app.example.com"
const TOKEN_URL = "https://acme-prod.snowflakecomputing.com/oauth/token-request"
const CLIENT_ID = "client+id/1="

function setup(answer = { status: 200, body: '{"access_token":"t"}' }) {
  const calls = [], lines = []
  const fetch = async (url, init) => {
    calls.push({ url, init })
    if (answer instanceof Error) throw answer
    return new Response(answer.body, { status: answer.status, headers: { "content-type": "application/json" } })
  }
  return { calls, lines, cfg: { tokenUrl: TOKEN_URL, clientId: CLIENT_ID, allowedOrigin: ORIGIN, fetch, log: (l) => lines.push(l) } }
}
const form = (o) => new URLSearchParams(o).toString()
const req = (body, headers = {}) => ({
  method: "POST", headers: { origin: ORIGIN, "content-type": "application/x-www-form-urlencoded", ...headers }, body,
})
const CODE = { grant_type: "authorization_code", code: "c", client_id: CLIENT_ID, redirect_uri: `${ORIGIN}/lakehouse/snowflake-redirect.html`, code_verifier: "v" }

test("forwards a code exchange to the account's token endpoint, unchanged, and returns Snowflake's answer", async () => {
  const s = setup()
  const r = await relay(req(form(CODE)), s.cfg)
  assert.equal(r.status, 200)
  assert.equal(r.body, '{"access_token":"t"}')
  assert.equal(r.headers["cache-control"], "no-store")
  assert.equal(s.calls.length, 1)
  assert.equal(s.calls[0].url, TOKEN_URL)
  assert.deepEqual(Object.fromEntries(new URLSearchParams(s.calls[0].init.body)), CODE)
})

test("forwards a refresh and passes Snowflake's error status through", async () => {
  const s = setup({ status: 400, body: '{"error":"invalid_grant"}' })
  const r = await relay(req(form({ grant_type: "refresh_token", refresh_token: "r", client_id: CLIENT_ID })), s.cfg)
  assert.equal(r.status, 400)
  assert.equal(r.body, '{"error":"invalid_grant"}')
})

test("logs the grant type and status only, never the request or the tokens", async () => {
  const s = setup()
  await relay(req(form(CODE)), s.cfg)
  assert.deepEqual(s.lines, ['{"grant_type":"authorization_code","status":200}'])
})

for (const [name, request, status] of [
  ["another origin", req(form(CODE), { origin: "https://evil.example" }), 403],
  ["no origin", req(form(CODE), { origin: undefined }), 403],
  ["a GET", { ...req(form(CODE)), method: "GET" }, 405],
  ["JSON", req(JSON.stringify(CODE), { "content-type": "application/json" }), 415],
  ["another client", req(form({ ...CODE, client_id: "other" })), 400],
  ["another grant", req(form({ ...CODE, grant_type: "password" })), 400],
  ["a client secret", req(form({ ...CODE, client_secret: "s" })), 400],
  ["a body over 16 KiB", req(form({ ...CODE, pad: "x".repeat(17000) })), 413],
]) {
  test(`refuses ${name} without calling Snowflake`, async () => {
    const s = setup()
    const r = await relay(request, s.cfg)
    assert.equal(r.status, status)
    assert.equal(JSON.parse(r.body).error, "invalid_request")
    assert.equal(s.calls.length, 0)
  })
}

for (const key of ["tokenUrl", "clientId", "allowedOrigin"]) {
  test(`refuses everything when ${key} isn't set, even a request that leaves the field out`, async () => {
    const s = setup()
    const cfg = { ...s.cfg, [key]: undefined }
    const body = key === "clientId" ? form({ ...CODE, client_id: undefined }).replace(/&?client_id=undefined/, "") : form(CODE)
    const r = await relay(key === "allowedOrigin" ? req(body, { origin: undefined }) : req(body), cfg)
    assert.equal(r.status, 500)
    assert.equal(s.calls.length, 0)
  })
}

test("answers 502 when Snowflake can't be reached", async () => {
  const s = setup(new TypeError("fetch failed"))
  const r = await relay(req(form(CODE)), s.cfg)
  assert.equal(r.status, 502)
  assert.equal(JSON.parse(r.body).error, "temporarily_unavailable")
})

test("answers 502, and logs no status, when the connection fails while reading Snowflake's answer", async () => {
  const s = setup()
  s.cfg.fetch = async () => ({ status: 200, headers: new Headers(), text: async () => { throw new TypeError("terminated") } })
  const r = await relay(req(form(CODE)), s.cfg)
  assert.equal(r.status, 502)
  assert.deepEqual(s.lines, ['{"grant_type":"authorization_code","error":"TypeError"}'])
})

test("lowerHeaders lowercases header names (Lambda and Azure Functions differ)", () => {
  assert.deepEqual(lowerHeaders({ Origin: "o", "Content-Type": "t" }), { origin: "o", "content-type": "t" })
  assert.deepEqual(lowerHeaders(undefined), {})
})
