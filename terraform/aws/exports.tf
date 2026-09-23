# TraceForce's control-plane metadata, mirrored into the same S3 Tables namespace so
# Claude can join it against agent_events with plain SQL. v1 = 17 tables: identity
# (devices, sandboxes, accounts, installs and their junction, MDM owners), agent names,
# the two finding types with their bridges to the logs (conversations, files), and the
# whole MCP chain (instances, junction to installs, rollups, global + org catalogs,
# categories).
# Deferred until a customer question needs them: user groups and IdP users, issues and
# policies (each comes with its lookup chain).
#
# Flow: a TraceForce job (TraceForce's export job) writes one full
# snapshot per table per day as gzipped JSON Lines to
#   ${exports_root}<table>/dt=YYYY-MM-DD/<HHMMSS>.jsonl.gz
# under the same TraceForce role your Storage Provider grant already trusts; the job only
# creates new keys, it never overwrites or deletes. The daily "exports" run of the state machine MERGEs the newest
# snapshot into the Iceberg table and deletes rows that vanished from it, so the Iceberg
# table always equals the last snapshot. Old snapshots are the customer's to expire.
#
# One column list per table drives three things: the Glue source table (all strings,
# parsed from JSON), the Iceberg target table (typed), and the CASTs in the MERGE SQL.
# Postgres -> Iceberg: uuid/text -> string, integer -> int, bigint -> long,
# boolean -> boolean, timestamptz -> timestamp (UTC), numeric -> double, jsonb/array -> string.
locals {
  export_tables = module.schema.export_tables

  # "name:type" -> { name, type }
  export_columns = {
    for t, cols in local.export_tables : t => [
      for c in cols : { name = split(":", c)[0], type = split(":", c)[1] }
    ]
  }
}

# Source: the newest JSONL snapshot, read as strings and CAST in SQL.
resource "aws_glue_catalog_table" "export_src" {
  for_each = local.export_columns

  name          = "export_${each.key}"
  database_name = aws_glue_catalog_database.lakehouse.name
  table_type    = "EXTERNAL_TABLE"
  description   = "TraceForce daily snapshot of ${each.key} (JSON Lines). Mirror source only; query the Iceberg table ${each.key} instead."

  parameters = {
    EXTERNAL                      = "TRUE"
    "projection.enabled"          = "true"
    "projection.dt.type"          = "date"
    "projection.dt.format"        = "yyyy-MM-dd"
    "projection.dt.range"         = "2026-09-01,NOW"
    "projection.dt.interval"      = "1"
    "projection.dt.interval.unit" = "DAYS"
    "storage.location.template"   = "${local.exports_root}${each.key}/dt=$${dt}/"
  }

  storage_descriptor {
    location      = "${local.exports_root}${each.key}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    dynamic "columns" {
      for_each = each.value
      content {
        name = columns.value.name
        type = "string"
      }
    }

    # No ignore.malformed.json: a malformed line must fail that table's MERGE loudly rather
    # than be dropped, because the DELETE step would then remove the rows it stood for.
    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
    }
  }

  partition_keys {
    name = "dt"
    type = "string"
  }
}

# Target: typed Iceberg table, same name as in TraceForce.
resource "aws_s3tables_table" "export" {
  for_each = local.export_columns

  name             = each.key
  namespace        = aws_s3tables_namespace.tf.namespace
  table_bucket_arn = aws_s3tables_table_bucket.lakehouse.arn
  format           = "ICEBERG"

  metadata {
    iceberg {
      schema {
        dynamic "field" {
          for_each = each.value
          content {
            name     = field.value.name
            type     = field.value.type
            required = field.value.name == "id"
          }
        }
      }
    }
  }
}

locals {
  # MERGE + DELETE statements per table, rendered once and embedded in the state machine.
  export_sql = {
    for t, cols in local.export_columns : t => {
      merge = templatefile("${path.module}/sql/mirror_export_merge.sql.tftpl", {
        target  = "\"s3tablescatalog/${aws_s3tables_table_bucket.lakehouse.name}\".\"${aws_s3tables_namespace.tf.namespace}\".\"${t}\""
        source  = "\"${aws_glue_catalog_database.lakehouse.name}\".\"export_${t}\""
        columns = cols
      })
      delete = templatefile("${path.module}/sql/mirror_export_delete.sql.tftpl", {
        target = "\"s3tablescatalog/${aws_s3tables_table_bucket.lakehouse.name}\".\"${aws_s3tables_namespace.tf.namespace}\".\"${t}\""
        source = "\"${aws_glue_catalog_database.lakehouse.name}\".\"export_${t}\""
      })
    }
  }
}
