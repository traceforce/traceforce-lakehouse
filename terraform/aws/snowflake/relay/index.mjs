// Lambda handler for the dashboards' token relay (dashboard_relay.tf); the logic is shared with
// the Azure Function: terraform/snowflake/relay/relay.mjs.
import { relay, lowerHeaders } from "./relay.mjs"

const cfg = { tokenUrl: process.env.TOKEN_URL, clientId: process.env.CLIENT_ID, allowedOrigin: process.env.ALLOWED_ORIGIN }

export const handler = async (event) => {
  const body = event.isBase64Encoded ? Buffer.from(event.body ?? "", "base64").toString("utf8") : (event.body ?? "")
  const r = await relay({ method: event.requestContext?.http?.method, headers: lowerHeaders(event.headers), body }, cfg)
  return { statusCode: r.status, headers: r.headers, body: r.body }
}
