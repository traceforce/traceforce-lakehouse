# The logs bucket, read so the module can refuse to deploy in a different region than the data
# lives in (residency, and every hourly scan would otherwise cross regions).
data "aws_s3_bucket" "logs" {
  bucket = var.logs_bucket
}

# Where Snowflake writes the Iceberg tables' data and metadata files: a plain bucket this module
# owns, never the logs bucket (a lifecycle rule there would delete table files). force_destroy: the
# tables are derived and re-ingestable from the logs, and dropping a Snowflake-managed table leaves
# its files (at least through the data retention period), so destroy must be able to empty the
# bucket. No versioning (Iceberg keeps its own snapshots; versioning would keep every deleted data
# file as a noncurrent version) and no lifecycle rule.
resource "aws_s3_bucket" "iceberg" {
  depends_on    = [snowflake_execute.session_warehouse] # checks.tf: fail fast, before creating anything here
  bucket        = local.iceberg_bucket
  force_destroy = true

  lifecycle {
    precondition {
      condition     = data.aws_s3_bucket.logs.bucket_region == local.region
      error_message = "The aws provider region (${local.region}) must be the logs bucket's region (${data.aws_s3_bucket.logs.bucket_region}). Set provider \"aws\" { region = \"${data.aws_s3_bucket.logs.bucket_region}\" } in your root configuration."
    }
  }
}

resource "aws_s3_bucket_public_access_block" "iceberg" {
  bucket                  = aws_s3_bucket.iceberg.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Snowflake writes without ACLs; owner-enforced keeps every object owned by this account.
resource "aws_s3_bucket_ownership_controls" "iceberg" {
  bucket = aws_s3_bucket.iceberg.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "iceberg" {
  bucket = aws_s3_bucket.iceberg.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Refuse plain-HTTP requests, which S3 otherwise serves. Snowflake and Terraform use HTTPS.
# Deny-only, so the public access block above accepts it.
resource "aws_s3_bucket_policy" "iceberg" {
  depends_on = [aws_s3_bucket_public_access_block.iceberg] # after the block, not alongside it
  bucket     = aws_s3_bucket.iceberg.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.iceberg.arn, "${aws_s3_bucket.iceberg.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}
