// Azure Function (Node.js v3 programming model, no packages) for the dashboards' token relay
// (dashboard_relay.tf); the logic is shared with the AWS Lambda: terraform/snowflake/relay/relay.mjs.
import { relay, lowerHeaders } from "../relay.mjs"

const cfg = { tokenUrl: process.env.TOKEN_URL, clientId: process.env.CLIENT_ID, allowedOrigin: process.env.ALLOWED_ORIGIN }

export default async function relayToken(context, req) {
  const body = typeof req.rawBody === "string" ? req.rawBody : Buffer.isBuffer(req.rawBody) ? req.rawBody.toString("utf8") : ""
  const r = await relay({ method: req.method, headers: lowerHeaders(req.headers), body }, { ...cfg, log: (l) => context.log(l) })
  return { status: r.status, headers: r.headers, body: r.body }
}
