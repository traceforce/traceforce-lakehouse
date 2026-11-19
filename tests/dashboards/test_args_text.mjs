#!/usr/bin/env node
// The incident-triage page's argsText (which part of a tool call's arguments it shows), offline.
//
//   node tests/dashboards/test_args_text.mjs   # needs Node 18 or later
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const page = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "..", "examples", "dashboards", "incident-triage", "index.html"), "utf8");
const src = page.match(/\n {2}const ARG_KEYS[\s\S]*?\n {2}function argsText[\s\S]*?\n {2}\}\n/)[0];
const argsText = new Function(`${src}; return argsText;`)();

test("argsText", () => {
  assert.equal(argsText('{"command":"ls -la","description":"x"}'), "ls -la");
  assert.equal(argsText('{"bash_command":"rm","full_command":"rm -rf x","description":"d"}'), "rm -rf x");
  assert.equal(argsText('{"sql":"SELECT 1","url":"https://x"}'), "SELECT 1");
  const dispatch = '{"method":"GET","url":"/services/data/v60.0/query","skillId":"soql","queryParams":{"q":"SELECT Id FROM Account"}}';
  assert.equal(argsText(dispatch), "SELECT Id FROM Account");
  assert.equal(argsText('{"method":"GET","url":"/x","queryParams":{"limit":"5"}}'), "/x");
  assert.equal(argsText('{"mcp_server_name":"srv","mcp_tool_name":"fetch"}'), '{"mcp_server_name":"srv","mcp_tool_name":"fetch"}');
  assert.equal(argsText(null), "");
  assert.equal(argsText("rm -rf x"), "rm -rf x");
  assert.equal(argsText("null"), "null");
  assert.equal(argsText('[{"command":"x"}]'), '[{"command":"x"}]');
  // Cut off when stored: the first key found, by key order, whether or not it leads.
  assert.equal(argsText('{"command":"echo \\"hi\\" && rm -rf /tm'), 'echo "hi" && rm -rf /tm …');
  assert.equal(argsText('{"bash_command":"rm","description":"d","full_command":"rm -rf /very/lo'), "rm -rf /very/lo …");
  assert.equal(argsText(dispatch.slice(0, 100)), "SELECT Id FR …");
  assert.equal(argsText('{"bash_command":"rm","full_command":"rm x","description":"cut of'), "rm x");
  assert.equal(argsText('{"command":"a\\u00'), "a …");
  assert.equal(argsText('{"note":"has \\"command\\": \\"x\\" inside","other":"cut'), '{"note":"has \\"command\\": \\"x\\" inside","other":"cut');
});
