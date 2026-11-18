// The example dashboards' diagnosis of Snowflake failures that the query script's sign-in and
// warehouse choice produce (examples/dashboards/engines.mjs), offline, with messages recorded from
// snowflake-connector-python 4.8.1 and 5.2.0:
//
//   node tests/dashboards/test_snowflake_errors.mjs
//
// Needs Node 18 or newer.
import { test } from "node:test"
import assert from "node:assert/strict"
import { classifySnowflakeError } from "../../examples/dashboards/engines.mjs"

const NO_WAREHOUSE = "No usable query warehouse for the reader role"

test("the script's message when the reader role can use neither warehouse names the query warehouse and the fix", () => {
  const d = classifySnowflakeError(
    'no lakehouse warehouse for the reader role: "traceforce_lakehouse_query" and "traceforce_lakehouse" each does not exist or is not authorized -- re-apply the lakehouse module, or ask a Snowflake admin to grant the role USAGE on "traceforce_lakehouse_query" (002043 (02000): ...)',
  )
  assert.equal(d.what, NO_WAREHOUSE)
  assert.match(d.fix, /GRANT USAGE ON WAREHOUSE "traceforce_lakehouse_query" TO ROLE "traceforce_lakehouse_reader"/)
  assert.match(d.fix, /Re-apply the lakehouse module/)
})

test("an older script's 000606 says to update the plugin, with a default warehouse as the stopgap", () => {
  const d = classifySnowflakeError("000606 (57P03): No active warehouse selected in the current session.")
  assert.equal(d.what, NO_WAREHOUSE)
  assert.match(d.fix, /update the traceforce-lakehouse plugin/)
  assert.match(d.fix, /DEFAULT_WAREHOUSE = "traceforce_lakehouse_query"/)
  assert.doesNotMatch(d.fix, /Re-apply/)
})

test("a warehouse that can't run the query is named as the query warehouse", () => {
  const d = classifySnowflakeError("Warehouse 'traceforce_lakehouse_query' cannot be resumed because resource monitor 'X' has exceeded its quota.")
  assert.match(d.what, /"traceforce_lakehouse_query" can't run the query/)
})

// A user without the reader role, refused at sign-in because the script names the role there.
const NO_ROLE_4 = "390186 (08001): Failed to connect to DB: ORG-ACCOUNT.snowflakecomputing.com:443. Role 'traceforce_lakehouse_reader' specified in the connect string is not granted to this user, or is not permitted for the credentials being used. Contact your local system administrator, or attempt to login with another role, e.g. PUBLIC."
const NO_ROLE_5 = "390186 (08001): Failed to login: Login error: Role 'traceforce_lakehouse_reader' specified in the connect string is not granted to this user, or is not permitted for the credentials being used. Contact your local system administrator, or attempt to login with another role, e.g. PUBLIC., code: 390186"

for (const [version, text] of [["4", NO_ROLE_4], ["5", NO_ROLE_5]]) {
  test(`a user without the reader role is told so, not that the account is unreachable (connector ${version})`, () => {
    const d = classifySnowflakeError(text, "your connections.toml connection")
    assert.equal(d.what, "You don't have the lakehouse's reader role")
    assert.match(d.fix, /GRANT ROLE "traceforce_lakehouse_reader" TO USER/)
  })
}

// Missing or mistyped connections.toml connection: connector 5 and connectors 3/4 word it differently.
for (const [version, missing, mistyped] of [
  ["5", "000007: Configuration error: Connection 'default' not found in config files", "000007: Configuration error: Connection 'nope' not found in config files"],
  ["4", "Invalid connection_name 'default', known ones are []", "Invalid connection_name 'nope', known ones are ['deploy_norole']"],
]) {
  test(`no connection configured means no credentials found (connector ${version})`, () => {
    assert.equal(classifySnowflakeError(missing, "your connections.toml connection").what, "No Snowflake credentials found")
  })
  test(`a mistyped connection name is named (connector ${version})`, () => {
    assert.equal(classifySnowflakeError(mistyped, "your connections.toml connection").what, 'connections.toml has no connection named "nope"')
  })
}

test("an unreachable account is still diagnosed as unreachable", () => {
  const d = classifySnowflakeError("250003 (08001): Failed to connect to DB: nope-nope.snowflakecomputing.com:443. 404 Not Found", "the SNOWFLAKE_* variables")
  assert.equal(d.what, "Couldn't reach the Snowflake account")
})
