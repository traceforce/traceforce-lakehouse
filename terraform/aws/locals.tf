data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# The logs bucket, read so the module can refuse to deploy in a different region than the
# data lives in (residency, and every hourly scan would otherwise cross regions).
data "aws_s3_bucket" "logs" {
  bucket = var.logs_bucket
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  # Where scout's OTel exporter writes activity objects -- Hive key=value for agent and upload day (UTC):
  #   s3://<bucket>/<prefix>/telemetry/agent=<AGENT_IDENTITY_*>/dt=<YYYYMMDD>/<serial>/<email>[_<org>]/<session>/<ts>_<uuid>_logs|traces.json.gz
  # Floor for the projected day range: no collector wrote the telemetry/ layout before this
  # date, so the projection never needs to enumerate earlier days. Never move it forward.
  day_layout_since = "20260923"
  prefix_slash     = var.logs_prefix == "" ? "" : "${var.logs_prefix}/"
  raw_root         = "s3://${var.logs_bucket}/${local.prefix_slash}telemetry/"
  # TraceForce's daily metadata snapshots land under this subtree of the logs bucket (written
  # by TraceForce's storage role). Query results go to a bucket this module owns instead, so
  # nothing outside your account can read what your engineers ask.
  derived_root   = "s3://${var.logs_bucket}/${local.prefix_slash}_traceforce/lakehouse/"
  exports_root   = "${local.derived_root}exports/"
  results_bucket = "${local.name}-results-${local.account_id}-${local.region}"
  athena_results = "s3://${local.results_bucket}/"

  # Fixed names: the skill, docs and Athena examples all assume them.
  name      = "traceforce-lakehouse"
  namespace = "traceforce"
}
