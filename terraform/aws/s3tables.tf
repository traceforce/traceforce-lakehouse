# S3 Tables: the Iceberg table bucket, namespace and the agent_events table.
# Compaction and snapshot expiry are handled by S3 Tables itself; nothing here schedules them.

resource "aws_s3tables_table_bucket" "lakehouse" {
  name = local.name

  maintenance_configuration = {
    iceberg_unreferenced_file_removal = {
      status = "enabled"
      settings = {
        non_current_days  = 10
        unreferenced_days = 3
      }
    }
  }

  lifecycle {
    precondition {
      condition     = data.aws_s3_bucket.logs.bucket_region == local.region
      error_message = "The aws provider region (${local.region}) must be the logs bucket's region (${data.aws_s3_bucket.logs.bucket_region}). Set provider \"aws\" { region = \"${data.aws_s3_bucket.logs.bucket_region}\" } in your root configuration."
    }
  }
}

resource "aws_s3tables_namespace" "tf" {
  namespace        = local.namespace
  table_bucket_arn = aws_s3tables_table_bucket.lakehouse.arn
}

# One row per log record or span. Column names mirror the TraceForce platform schema
# (device_native_id, device_uuid, sandbox_native_id) so joins to the exported tables
# read the same on both sides. Unpartitioned for the POC: S3 Tables compaction keeps
# files healthy and volumes are small; partition by (agent, day(ts)) when needed.
resource "aws_s3tables_table" "agent_events" {
  name             = "agent_events"
  namespace        = aws_s3tables_namespace.tf.namespace
  table_bucket_arn = aws_s3tables_table_bucket.lakehouse.arn
  format           = "ICEBERG"

  maintenance_configuration = {
    iceberg_compaction = {
      status   = "enabled"
      settings = { target_file_size_mb = 128 }
    }
    iceberg_snapshot_management = {
      status   = "enabled"
      settings = { max_snapshot_age_hours = 168, min_snapshots_to_keep = 1 }
    }
  }

  metadata {
    iceberg {
      schema {
        dynamic "field" {
          for_each = local.agent_events_schema
          content {
            name     = field.value.name
            type     = field.value.type
            required = field.value.required
          }
        }
      }
    }
  }
}


# Iceberg primitive types only; a schema change replaces the table (see README, Upgrades).
locals {
  agent_events_schema = module.schema.agent_events
}
