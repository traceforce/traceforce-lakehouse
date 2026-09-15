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

  # Where TraceForce's collector writes activity objects, per agent and upload day (UTC):
  #   s3://<bucket>/<prefix>/conversations/<AGENT_IDENTITY_*>/dt=<YYYYMMDD>/<serial>/<email>[_<org>]/<session>/<ts>_<uuid>_logs|traces.json.gz
  # First day the collector wrote the day-partitioned layout; the projection enumerates from here.
  day_layout_since = "20260915"
  prefix_slash     = var.logs_prefix == "" ? "" : "${var.logs_prefix}/"
  raw_root         = "s3://${var.logs_bucket}/${local.prefix_slash}conversations/"
  # TraceForce's daily metadata snapshots land under this subtree of the logs bucket (written
  # by TraceForce's storage role). Query results go to a bucket this module owns instead, so
  # nothing outside your account can read what your engineers ask.
  derived_root   = "s3://${var.logs_bucket}/${local.prefix_slash}_traceforce/lakehouse/"
  exports_root   = "${local.derived_root}exports/"
  results_bucket = "${local.name}-results-${local.account_id}-${local.region}"
  athena_results = "s3://${local.results_bucket}/"

  # Only these four rails are in the standardized OTLP GenAI format. ChatGPT (browser
  # capture, .json.zip deltas) and pre-2026-08-28 legacy layouts are deliberately excluded.
  agents = {
    "AGENT_IDENTITY_CLAUDE_CODE"    = 111
    "AGENT_IDENTITY_CURSOR"         = 2
    "AGENT_IDENTITY_CLAUDE"         = 1
    "AGENT_IDENTITY_GITHUB_COPILOT" = 8
  }

  # Fixed names: the skill, docs and Athena examples all assume them.
  name      = "traceforce-lakehouse"
  namespace = "traceforce"
}
