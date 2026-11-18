# Two roles Snowflake assumes, so the identity that reads the raw logs can never write table data
# and the writer can never read the logs: one reads (through the storage integration), one writes
# the Iceberg bucket (through the external volume). Each trusts only its own Snowflake
# object: the IAM user is one per Snowflake account, the external id is per object. Both come
# from describe_output, which the provider fills in on the first apply.

locals {
  # The Athena ingest role's read statements, narrowed to what Snowflake reads: objects under the
  # two subtrees, and listing limited to them (Athena also lists the rest of _traceforce/lakehouse/,
  # where its ingest writes).
  raw_statements = concat([
    {
      Sid      = "ReadRawAndExports"
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = ["${local.bucket_arn}/${local.prefix_slash}telemetry/*", "${local.bucket_arn}/${local.prefix_slash}_traceforce/lakehouse/exports/*"]
    },
    {
      Sid       = "ListPrefixOnly"
      Effect    = "Allow"
      Action    = ["s3:ListBucket"]
      Resource  = local.bucket_arn
      Condition = { StringLike = { "s3:prefix" = ["${local.prefix_slash}telemetry/*", "${local.prefix_slash}_traceforce/lakehouse/exports/*"] } }
    },
    {
      Sid      = "LogsBucketLocation"
      Effect   = "Allow"
      Action   = ["s3:GetBucketLocation"]
      Resource = local.bucket_arn
    },
    ], var.logs_kms_key_arn == null ? [] : [{
      Sid      = "LogsBucketKey"
      Effect   = "Allow"
      Action   = ["kms:Decrypt", "kms:DescribeKey"]
      Resource = var.logs_kms_key_arn
  }])

  raw_trust = snowflake_storage_integration_aws.raw.describe_output[0]
  iceberg_trust = (
    snowflake_external_volume.lakehouse.describe_output[0].storage_locations[0].s3_storage_location[0]
  )
}

resource "aws_iam_role" "raw_reader" {
  depends_on = [snowflake_execute.session_warehouse] # checks.tf: fail fast
  name       = local.raw_role_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = local.raw_trust.iam_user_arn }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "sts:ExternalId" = local.raw_trust.external_id } }
    }]
  })
}

resource "aws_iam_role_policy" "raw_reader" {
  name   = local.raw_role_name
  role   = aws_iam_role.raw_reader.id
  policy = jsonencode({ Version = "2012-10-17", Statement = local.raw_statements })
}

resource "aws_iam_role" "iceberg_writer" {
  depends_on = [snowflake_execute.session_warehouse] # checks.tf: fail fast
  name       = local.iceberg_role_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = local.iceberg_trust.storage_aws_iam_user_arn }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "sts:ExternalId" = local.iceberg_trust.storage_aws_external_id } }
    }]
  })
}

# Enough for Snowflake-managed Iceberg tables: create, write, update, delete and drop were tested.
resource "aws_iam_role_policy" "iceberg_writer" {
  name = local.iceberg_role_name
  role = aws_iam_role.iceberg_writer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "IcebergObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:GetObjectVersion", "s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource = "${aws_s3_bucket.iceberg.arn}/*"
      },
      {
        Sid      = "IcebergBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.iceberg.arn
      },
    ]
  })
}

# IAM is eventually consistent: the first stage LIST or Iceberg write right after a role, its policy
# or its trust changes can fail. Snowflake could use new roles about 10 s after creation and an
# updated trust within 30 s in testing; 30 s leaves margin. Everything that reads or writes S3
# waits for them.
resource "time_sleep" "raw_reader_propagation" {
  depends_on      = [aws_iam_role_policy.raw_reader]
  triggers        = { role = aws_iam_role.raw_reader.arn, trust = aws_iam_role.raw_reader.assume_role_policy, policy = aws_iam_role_policy.raw_reader.policy }
  create_duration = "30s"
}

resource "time_sleep" "iceberg_write_propagation" {
  depends_on      = [aws_iam_role_policy.iceberg_writer]
  triggers        = { role = aws_iam_role.iceberg_writer.arn, trust = aws_iam_role.iceberg_writer.assume_role_policy, policy = aws_iam_role_policy.iceberg_writer.policy }
  create_duration = "30s"
}
