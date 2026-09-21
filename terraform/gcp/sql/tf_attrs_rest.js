// attrs_json = the decoded attribute object minus the four big keys that get their own
// columns (gen_ai.input.messages, gen_ai.output.messages, gen_ai.tool.call.arguments,
// gen_ai.tool.call.result). Mirrors the AWS map_filter(a,(k,v)->k NOT IN (...)).
if (attrs === null || attrs === undefined) return null;
var drop = {
  "gen_ai.input.messages": 1, "gen_ai.output.messages": 1,
  "gen_ai.tool.call.arguments": 1, "gen_ai.tool.call.result": 1
};
var out = {};
for (var k in attrs) { if (attrs.hasOwnProperty(k) && !drop[k]) out[k] = attrs[k]; }
return out;
