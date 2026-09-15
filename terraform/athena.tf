# Query results live in a bucket this module owns, not in the logs bucket: the Storage
# Provider grant lets TraceForce's role read and write everything under your TraceForce
# prefix, and query results (what your engineers asked, joined with identity) must not be
# in that scope. SSE-S3 on purpose: S3 Tables rejects INSERT/MERGE from a workgroup that
# enforces SSE-KMS or CSE-KMS. Results are disposable and expire after 7 days.
resource "aws_s3_bucket" "results" {
  bucket        = local.results_bucket
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "results" {
  bucket                  = aws_s3_bucket.results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  bucket = aws_s3_bucket.results.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "results" {
  bucket = aws_s3_bucket.results.id
  rule {
    id     = "expire-results"
    status = "Enabled"
    filter {}
    expiration { days = 7 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

resource "aws_athena_workgroup" "lakehouse" {
  name        = local.name
  description = "TraceForce lakehouse: scheduled ingest plus read-only queries over agent_events"
  state       = "ENABLED"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    # A runaway query fails loudly instead of billing quietly. 50 GB is well above any
    # sane single query here.
    bytes_scanned_cutoff_per_query = 53687091200

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }

    result_configuration {
      output_location = local.athena_results
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }

  depends_on = [aws_s3_bucket_public_access_block.results]
}
