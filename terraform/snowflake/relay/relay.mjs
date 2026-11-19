// Token relay for the TraceForce UI dashboards' Snowflake sign-in, shared by the AWS Lambda
// (terraform/aws/snowflake/relay) and the Azure Function (terraform/azure/snowflake/relay).
// Browsers can't read Snowflake's OAuth token endpoint (it sends no CORS headers), so the dashboard
// posts the token request to the relay, which forwards its form fields. It only calls this one
// account's token endpoint, only for the dashboards' client, keeps nothing, and logs only the grant
// type and the HTTP status (never the request or the tokens).
// The platform's CORS settings (function URL / Function app) let only the console's origin read
// the answer.

const MAX_BODY = 16 * 1024
const GRANTS = new Set(["authorization_code", "refresh_token"])
const JSON_HEADERS = { "content-type": "application/json", "cache-control": "no-store" }

const refuse = (status, message) => ({
  status, headers: JSON_HEADERS, body: JSON.stringify({ error: "invalid_request", error_description: message }),
})

/**
 * @param {{ method: string, headers: Record<string, string | undefined>, body: string }} req  header names lowercased
 * @param {{ tokenUrl: string, clientId: string, allowedOrigin: string, log?: (line: string) => void, fetch?: typeof fetch }} cfg
 * @returns {Promise<{ status: number, headers: Record<string, string>, body: string }>}
 */
export async function relay(req, cfg) {
  const log = cfg.log ?? console.log
  // A missing setting would match a request that leaves the field out: refuse everything instead.
  if (!cfg.tokenUrl || !cfg.clientId || !cfg.allowedOrigin) return refuse(500, "The relay isn't configured.")
  if (req.method !== "POST") return refuse(405, "POST only.")
  // CORS already stops other sites' pages from reading the answer; this also turns them away.
  if (req.headers.origin !== cfg.allowedOrigin) return refuse(403, "Origin not allowed.")
  if (!(req.headers["content-type"] ?? "").toLowerCase().startsWith("application/x-www-form-urlencoded")) {
    return refuse(415, "Send application/x-www-form-urlencoded.")
  }
  if (req.body.length > MAX_BODY) return refuse(413, "Request too large.")
  const form = new URLSearchParams(req.body)
  if (!GRANTS.has(form.get("grant_type") ?? "")) return refuse(400, "grant_type must be authorization_code or refresh_token.")
  if (form.get("client_id") !== cfg.clientId) return refuse(400, "Unknown client_id.")
  if (form.has("client_secret")) return refuse(400, "The dashboards' client is public; send no client_secret.")

  let res, body
  try {
    res = await (cfg.fetch ?? fetch)(cfg.tokenUrl, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
      body: form.toString(),
      signal: AbortSignal.timeout(8000),
    })
    // In the try: fetch resolves on the headers, so a reset or the timeout can still come while reading.
    body = await res.text()
  } catch (e) {
    log(JSON.stringify({ grant_type: form.get("grant_type"), error: e?.name ?? "fetch failed" }))
    return { status: 502, headers: JSON_HEADERS, body: JSON.stringify({ error: "temporarily_unavailable", error_description: "Couldn't reach Snowflake's token endpoint." }) }
  }
  // Status only: the body holds the tokens.
  log(JSON.stringify({ grant_type: form.get("grant_type"), status: res.status }))
  return {
    status: res.status,
    headers: { "content-type": res.headers.get("content-type") ?? "application/json", "cache-control": "no-store" },
    body,
  }
}

/** Header names lowercased (Lambda and Azure Functions pass them in different cases). */
export const lowerHeaders = (h) => Object.fromEntries(Object.entries(h ?? {}).map(([k, v]) => [k.toLowerCase(), v]))
