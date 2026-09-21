// Decode an OTLP attributes array into a flat JSON object of text values, mirroring the
// AWS/Trino ingest (transform_values(multimap_from_entries(...))): first value wins on
// duplicate keys; scalars -> text; arrayValue -> its values as a JSON array string (empty
// -> "[]"); kvlist -> a one-level JSON object of text values. Values are all strings so the
// downstream JSON_VALUE(attrs,'$."key"') extraction matches Athena's element_at(map,'key').
// Used by a google_bigquery_routine; the ingest SQL calls it on resource and record attrs.
if (attrs === null || attrs === undefined) return null;
var arr = attrs;
if (!Array.isArray(arr)) return null;
function inner(v) {
  if (v === null || v === undefined) return null;
  if ("stringValue" in v) return String(v.stringValue);
  if ("intValue" in v) return String(v.intValue);
  if ("doubleValue" in v) return String(v.doubleValue);
  if ("boolValue" in v) return String(v.boolValue);
  return JSON.stringify(v);
}
function scalar(v) {
  if (v === null || v === undefined) return null;
  if ("stringValue" in v) return String(v.stringValue);
  if ("intValue" in v) return String(v.intValue);
  if ("doubleValue" in v) return String(v.doubleValue);
  if ("boolValue" in v) return String(v.boolValue);
  if ("arrayValue" in v) return JSON.stringify((v.arrayValue && v.arrayValue.values) || []);
  if ("kvlistValue" in v) {
    var o = {}, vals = (v.kvlistValue && v.kvlistValue.values) || [];
    for (var i = 0; i < vals.length; i++) {
      var e = vals[i];
      if (e && e.key != null && !(e.key in o)) o[e.key] = inner(e.value);
    }
    return JSON.stringify(o);
  }
  return null;
}
var out = {};
for (var i = 0; i < arr.length; i++) {
  var a = arr[i];
  if (a && a.key != null && !(a.key in out)) out[a.key] = scalar(a.value);
}
return out;
