# The ingest's SOURCE: a Glue table over the raw gzipped OTLP-JSON objects. Each object
# is one compact JSON document on a single line, so the table is a single string column
# and Athena's JSON functions unnest it. Nobody queries this table directly; it exists so
# the scheduled INSERT can read the objects in place.
#
# Partition projection over the four agent folders does two things: Athena only lists
# those prefixes (ChatGPT's .json.zip rail and legacy layouts are never touched), and
# every row gets its agent from the path for free.
resource "aws_glue_catalog_table" "raw_conversations" {
  name          = "raw_conversations"
  database_name = aws_glue_catalog_database.lakehouse.name
  table_type    = "EXTERNAL_TABLE"
  description   = "TraceForce raw activity objects, one OTLP-JSON document per row. Ingest source only; query agent_events instead."

  parameters = {
    EXTERNAL                    = "TRUE"
    "projection.enabled"        = "true"
    "projection.agent.type"     = "enum"
    "projection.agent.values"   = join(",", keys(local.agents))
    "storage.location.template" = "${local.raw_root}$${agent}/"
  }

  storage_descriptor {
    location      = local.raw_root
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    columns {
      name    = "doc"
      type    = "string"
      comment = "the whole OTLP-JSON document"
    }

    # LazySimpleSerDe's default field delimiter is the control character 0x01, which a
    # valid JSON document can never contain unescaped, so each line lands in `doc` whole.
    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"
    }
  }

  partition_keys {
    name = "agent"
    type = "string"
  }
}
