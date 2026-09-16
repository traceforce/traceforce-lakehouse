# Redaction and evidence

What the stored content columns contain, and where the matched sensitive value lives (never the lake).

- `content_input`, `content_output`, `tool_args`, `tool_result` are what TraceForce stored:
  when the org's policy redacts (the default), each matched sensitive value is replaced by a
  run of `*`; everything around it is intact. With redaction off they are verbatim.
- The findings tables say what was found (`type`, `category`), where (`conversation_id`,
  `file_id`, offsets, lines), when, and the triage state. They never contain the value.
- The matched sensitive *value* is in an evidence object outside the lake, referenced by the
  finding's `customer_storage` pointer; it is masked everywhere in the logs, so do not try
  to recover it from them. A containment
  finding's *command* is not a value and is not masked: recover it from the joined event's
  `tool_args`. For anything evidence-only, point the user to the TraceForce console or
  `GET /api/v1/sensitive-data-findings/{id}/content` (containment:
  `/api/v1/connector-containment-findings/{id}/content`), which are authorized and audited.
