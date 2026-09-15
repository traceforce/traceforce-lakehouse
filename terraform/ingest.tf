# One Step Functions state machine runs both jobs, chosen by input:
#   {"job":"ingest"}  every 15 minutes   -> flatten new raw objects into agent_events
#   {"job":"exports"} daily at 06:00 UTC -> MERGE the newest TraceForce metadata snapshots into their mirrors
# An input without "job" (the console default) runs the ingest.
# Athena does all the work; Step Functions only sequences statements and waits for them.

locals {
  sfn_name = "${local.name}-ingest"
  sfn_arn  = "arn:aws:states:${local.region}:${local.account_id}:stateMachine:${local.sfn_name}"

  agent_events_fqn = "\"s3tablescatalog/${aws_s3tables_table_bucket.lakehouse.name}\".\"${aws_s3tables_namespace.tf.namespace}\".\"agent_events\""

  ingest_sql = templatefile("${path.module}/sql/ingest_agent_events.sql.tftpl", {
    target          = local.agent_events_fqn
    raw             = "\"${aws_glue_catalog_database.lakehouse.name}\".\"raw_conversations\""
    agent_in_list   = join(", ", [for k in keys(local.agents) : "'${k}'"])
    agent_type_case = join(" ", [for k, v in local.agents : "WHEN '${k}' THEN ${v}"])
    cols            = join(", ", [for c in local.agent_events_schema : c.name])
  })

  # Athena's .sync integration surfaces a FAILED query as States.TaskFailed whatever the
  # cause (throttle, commit conflict, bad data), so one broad retry rule is all there is.
  athena_retry = [{
    ErrorEquals     = ["States.TaskFailed"]
    IntervalSeconds = 60
    MaxAttempts     = 2
    BackoffRate     = 2
  }]
  # The ingest statement can legitimately run for many minutes; retrying a timeout would
  # only burn the next slot. One retry covers a transient commit conflict.
  ingest_retry = [{
    ErrorEquals     = ["States.TaskFailed"]
    IntervalSeconds = 60
    MaxAttempts     = 1
  }]

  sfn_definition = {
    Comment = "TraceForce lakehouse: Athena ingest of raw activity objects and mirror of daily exports"
    StartAt = "Route"
    States = merge({
      Route = {
        Type = "Choice"
        Choices = [{
          And  = [{ Variable = "$.job", IsPresent = true }, { Variable = "$.job", StringEquals = "exports" }]
          Next = "MirrorExports"
        }]
        Default = "CheckOverlap"
      }
      # Two ingests running at once would both pass the anti-join and load the same objects
      # twice, so a run that finds another RUNNING execution simply ends. The daily exports
      # run counts too, so the ingest scheduled during it is skipped once; the next one catches up.
      CheckOverlap = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:sfn:listExecutions"
        Parameters = {
          StateMachineArn = local.sfn_arn
          StatusFilter    = "RUNNING"
          MaxResults      = 5
        }
        ResultSelector = { "running.$" = "States.ArrayLength($.Executions)" }
        ResultPath     = "$.overlap"
        Next           = "IsAlone"
      }
      IsAlone = {
        Type    = "Choice"
        Choices = [{ Variable = "$.overlap.running", NumericGreaterThan = 1, Next = "SkippedOverlapping" }]
        Default = "IngestAgentEvents"
      }
      SkippedOverlapping = { Type = "Succeed" }
      IngestAgentEvents = {
        Type     = "Task"
        Resource = "arn:aws:states:::athena:startQueryExecution.sync"
        Parameters = {
          QueryString           = local.ingest_sql
          WorkGroup             = aws_athena_workgroup.lakehouse.name
          QueryExecutionContext = { Database = aws_glue_catalog_database.lakehouse.name }
        }
        Retry = local.ingest_retry
        End   = true
      }
      },
      {
        MirrorExports = {
          Type       = "Pass"
          Result     = { tables = [for t, q in local.export_sql : { name = t, merge = q.merge, delete = q.delete }] }
          ResultPath = "$.exports"
          Next       = "ForEachTable"
        }
        ForEachTable = {
          Type           = "Map"
          ItemsPath      = "$.exports.tables"
          MaxConcurrency = 3
          ItemProcessor = {
            ProcessorConfig = { Mode = "INLINE" }
            StartAt         = "Merge"
            States = {
              Merge = {
                Type     = "Task"
                Resource = "arn:aws:states:::athena:startQueryExecution.sync"
                Parameters = {
                  "QueryString.$"       = "$.merge"
                  WorkGroup             = aws_athena_workgroup.lakehouse.name
                  QueryExecutionContext = { Database = aws_glue_catalog_database.lakehouse.name }
                }
                ResultPath = null
                Retry      = local.athena_retry
                # One table failing must not stop the others: record the error on the item and move on.
                Catch = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "TableFailed" }]
                Next  = "Delete"
              }
              Delete = {
                Type     = "Task"
                Resource = "arn:aws:states:::athena:startQueryExecution.sync"
                Parameters = {
                  "QueryString.$"       = "$.delete"
                  WorkGroup             = aws_athena_workgroup.lakehouse.name
                  QueryExecutionContext = { Database = aws_glue_catalog_database.lakehouse.name }
                }
                ResultPath = null
                Retry      = local.athena_retry
                Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "TableFailed" }]
                End        = true
              }
              TableFailed = { Type = "Pass", End = true }
            }
          }
          Next = "CountFailures"
        }
        # After every table has had its turn, fail the execution if any of them failed, so the
        # run is visible as an error (the per-item errors are in the execution history).
        CountFailures = {
          Type       = "Pass"
          Parameters = { "failed.$" = "States.ArrayLength($[?(@.error)])" }
          Next       = "AnyFailed"
        }
        AnyFailed = {
          Type    = "Choice"
          Choices = [{ Variable = "$.failed", NumericGreaterThan = 0, Next = "MirrorIncomplete" }]
          Default = "MirrorDone"
        }
        MirrorDone       = { Type = "Succeed" }
        MirrorIncomplete = { Type = "Fail", Error = "MirrorIncomplete", Cause = "One or more export tables failed to merge; see the Map iterations in this execution." }
      }
    )
  }
}

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/vendedlogs/states/${local.sfn_name}"
  retention_in_days = 30
}

resource "aws_sfn_state_machine" "ingest" {
  name       = local.sfn_name
  role_arn   = aws_iam_role.sfn.arn
  definition = jsonencode(local.sfn_definition)

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = false
    level                  = "ERROR"
  }

  depends_on = [aws_iam_role_policy.sfn]
}

# The one operational signal: any failed execution (ingest or exports) raises this alarm.
# With no SNS topic it still shows as ALARM in the CloudWatch console.
resource "aws_cloudwatch_metric_alarm" "runs_failed" {
  alarm_name          = "${local.name}-runs-failed"
  alarm_description   = "A TraceForce lakehouse ingest or exports run failed. Open the state machine's execution history for the cause."
  namespace           = "AWS/States"
  metric_name         = "ExecutionsFailed"
  dimensions          = { StateMachineArn = aws_sfn_state_machine.ingest.arn }
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_sns_topic_arn == null ? [] : [var.alarm_sns_topic_arn]
  ok_actions          = var.alarm_sns_topic_arn == null ? [] : [var.alarm_sns_topic_arn]
}

# ---------------------------------------------------------------------------------------
# IAM: the state machine's role. Reads raw objects under the TraceForce prefix only, writes
# only under <prefix>/_traceforce/lakehouse/, and touches only this module's table bucket.
# ---------------------------------------------------------------------------------------
locals {
  bucket_arn         = "arn:aws:s3:::${var.logs_bucket}"
  raw_objects        = "${local.bucket_arn}/${local.prefix_slash}conversations/*"
  exports_objects    = "${local.bucket_arn}/${local.prefix_slash}_traceforce/lakehouse/exports/*"
  results_bucket_arn = aws_s3_bucket.results.arn

  table_bucket_tables = "${aws_s3tables_table_bucket.lakehouse.arn}/table/*"

  glue_catalog_arns = [
    "arn:aws:glue:${local.region}:${local.account_id}:catalog",
    "arn:aws:glue:${local.region}:${local.account_id}:catalog/s3tablescatalog",
    "arn:aws:glue:${local.region}:${local.account_id}:catalog/s3tablescatalog/${aws_s3tables_table_bucket.lakehouse.name}",
  ]
  glue_lakehouse_arns = [
    "arn:aws:glue:${local.region}:${local.account_id}:database/s3tablescatalog/${aws_s3tables_table_bucket.lakehouse.name}/${aws_s3tables_namespace.tf.namespace}",
    "arn:aws:glue:${local.region}:${local.account_id}:table/s3tablescatalog/${aws_s3tables_table_bucket.lakehouse.name}/${aws_s3tables_namespace.tf.namespace}/*",
  ]
  glue_helper_arns = [
    "arn:aws:glue:${local.region}:${local.account_id}:database/${aws_glue_catalog_database.lakehouse.name}",
    "arn:aws:glue:${local.region}:${local.account_id}:table/${aws_glue_catalog_database.lakehouse.name}/*",
  ]

  athena_read_actions = [
    "athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults",
    "athena:StopQueryExecution", "athena:GetWorkGroup", "athena:ListQueryExecutions",
    "athena:GetQueryResultsStream", "athena:BatchGetQueryExecution",
  ]
  s3tables_read_actions = [
    "s3tables:GetTableBucket", "s3tables:GetNamespace", "s3tables:ListNamespaces", "s3tables:ListTables",
    "s3tables:GetTable", "s3tables:GetTableData", "s3tables:GetTableMetadataLocation",
  ]
  s3tables_write_actions = ["s3tables:PutTableData", "s3tables:UpdateTableMetadataLocation"]

  # Athena result files: what the Athena docs list for an output location.
  results_statements = [
    {
      Sid      = "AthenaResults"
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
      Resource = "${local.results_bucket_arn}/*"
    },
    {
      Sid      = "ResultsBucket"
      Effect   = "Allow"
      Action   = ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"]
      Resource = local.results_bucket_arn
    },
    {
      Sid      = "LogsBucketLocation"
      Effect   = "Allow"
      Action   = ["s3:GetBucketLocation"]
      Resource = local.bucket_arn
    },
  ]
  kms_statements = var.logs_kms_key_arn == null ? [] : [{
    Sid      = "LogsBucketKey"
    Effect   = "Allow"
    Action   = ["kms:Decrypt", "kms:DescribeKey"]
    Resource = var.logs_kms_key_arn
  }]
}

resource "aws_iam_role" "sfn" {
  name = "${local.name}-sfn"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "sfn" {
  name = "lakehouse-ingest"
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "Athena"
        Effect   = "Allow"
        Action   = concat(local.athena_read_actions, ["athena:GetDataCatalog"])
        Resource = [aws_athena_workgroup.lakehouse.arn, "arn:aws:athena:${local.region}:${local.account_id}:datacatalog/*"]
      },
      {
        Sid      = "GlueRead"
        Effect   = "Allow"
        Action   = ["glue:GetCatalog", "glue:GetCatalogs", "glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables", "glue:GetPartition", "glue:GetPartitions", "glue:BatchGetPartition"]
        Resource = concat(local.glue_catalog_arns, local.glue_lakehouse_arns, local.glue_helper_arns)
      },
      {
        Sid      = "GlueCommitIceberg"
        Effect   = "Allow"
        Action   = ["glue:UpdateTable"]
        Resource = concat(local.glue_catalog_arns, local.glue_lakehouse_arns)
      },
      {
        Sid      = "LakeFormationVendedAccess"
        Effect   = "Allow"
        Action   = ["lakeformation:GetDataAccess"]
        Resource = "*"
      },
      {
        Sid      = "TableBucket"
        Effect   = "Allow"
        Action   = concat(local.s3tables_read_actions, local.s3tables_write_actions)
        Resource = [aws_s3tables_table_bucket.lakehouse.arn, local.table_bucket_tables]
      },
      {
        Sid      = "ReadRawAndExports"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = [local.raw_objects, local.exports_objects]
      },
      {
        Sid      = "ListPrefixOnly"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = local.bucket_arn
        Condition = {
          StringLike = { "s3:prefix" = ["${local.prefix_slash}conversations/*", "${local.prefix_slash}_traceforce/lakehouse/*"] }
        }
      },
      {
        Sid      = "OverlapCheck"
        Effect   = "Allow"
        Action   = ["states:ListExecutions"]
        Resource = local.sfn_arn
      },
      {
        # CloudWatch Logs delivery for Step Functions requires "*" (AWS documented).
        Sid      = "Logging"
        Effect   = "Allow"
        Action   = ["logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery", "logs:DeleteLogDelivery", "logs:ListLogDeliveries", "logs:PutResourcePolicy", "logs:DescribeResourcePolicies", "logs:DescribeLogGroups"]
        Resource = "*"
      },
    ], local.results_statements, local.kms_statements)
  })
}

# ---------------------------------------------------------------------------------------
# Schedules
# ---------------------------------------------------------------------------------------
resource "aws_iam_role" "scheduler" {
  name = "${local.name}-scheduler"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "start-ingest"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "states:StartExecution", Resource = aws_sfn_state_machine.ingest.arn }]
  })
}

resource "aws_scheduler_schedule" "ingest" {
  name                         = "${local.name}-ingest"
  description                  = "TraceForce lakehouse: load new activity objects into agent_events"
  schedule_expression          = "rate(15 minutes)"
  schedule_expression_timezone = "UTC"
  flexible_time_window { mode = "OFF" }
  target {
    arn      = aws_sfn_state_machine.ingest.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ job = "ingest" })
  }
}

resource "aws_scheduler_schedule" "exports" {
  name                         = "${local.name}-exports"
  description                  = "TraceForce lakehouse: mirror the daily TraceForce metadata snapshots"
  schedule_expression          = "cron(0 6 * * ? *)" # TraceForce writes the snapshots around 04:00 UTC
  schedule_expression_timezone = "UTC"
  flexible_time_window { mode = "OFF" }
  target {
    arn      = aws_sfn_state_machine.ingest.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ job = "exports" })
  }
}

# ---------------------------------------------------------------------------------------
# Read-only query access, as a policy document the customer attaches to whatever identity
# their engineers (and Claude Code) already use. It can read the Iceberg tables and its
# own Athena results; it cannot read the raw objects.
# ---------------------------------------------------------------------------------------
locals {
  query_policy = {
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "Athena"
        Effect   = "Allow"
        Action   = concat(local.athena_read_actions, ["athena:GetDataCatalog", "athena:GetDatabase", "athena:GetTableMetadata", "athena:ListDatabases", "athena:ListTableMetadata"])
        Resource = [aws_athena_workgroup.lakehouse.arn, "arn:aws:athena:${local.region}:${local.account_id}:datacatalog/*"]
      },
      {
        Sid      = "GlueRead"
        Effect   = "Allow"
        Action   = ["glue:GetCatalog", "glue:GetCatalogs", "glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables", "glue:GetPartition", "glue:GetPartitions", "glue:BatchGetPartition"]
        Resource = concat(local.glue_catalog_arns, local.glue_lakehouse_arns, local.glue_helper_arns)
      },
      {
        Sid      = "LakeFormationVendedAccess"
        Effect   = "Allow"
        Action   = ["lakeformation:GetDataAccess"]
        Resource = "*"
      },
      {
        Sid      = "TableBucketRead"
        Effect   = "Allow"
        Action   = local.s3tables_read_actions
        Resource = [aws_s3tables_table_bucket.lakehouse.arn, local.table_bucket_tables]
      },
    ], local.results_statements) # no KMS: this policy reads Iceberg data and SSE-S3 results only
  }
}
