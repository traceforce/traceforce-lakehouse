# The ingest's SOURCE: a Glue table over the raw gzipped OTLP-JSON objects. Each object
# is one compact JSON document on a single line, so the table is a single string column
# and Athena's JSON functions unnest it. Nobody queries this table directly; it exists so
# the scheduled INSERT can read the objects in place.
#
# Two projected partitions: the agent folder (Athena lists only the four supported agents;
# ChatGPT's .json.zip capture and pre-day-partition layouts are never touched) and the
# upload day the collector writes as dt=YYYYMMDD right after the agent. The ingest reads
# only the last few days of folders, so cost and run time do not grow with history.
# Requires collector release 1.0.42 or later; objects written by older collectors (flat
# layout, no dt= folder) are not read.
resource "aws_glue_catalog_table" "raw_conversations" {
  name          = "raw_conversations"
  database_name = aws_glue_catalog_database.lakehouse.name
  table_type    = "EXTERNAL_TABLE"
  description   = "TraceForce raw activity objects, one OTLP-JSON document per row. Ingest source only; query agent_events instead."

  parameters = {
    EXTERNAL                      = "TRUE"
    "projection.enabled"          = "true"
    "projection.agent.type"       = "enum"
    "projection.agent.values"     = join(",", keys(local.agents))
    "projection.dt.type"          = "date"
    "projection.dt.format"        = "yyyyMMdd"
    "projection.dt.range"         = "${local.day_layout_since},NOW+1DAYS"
    "projection.dt.interval"      = "1"
    "projection.dt.interval.unit" = "DAYS"
    "storage.location.template"   = "${local.raw_root}$${agent}/dt=$${dt}/"
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
  partition_keys {
    name = "dt"
    type = "string"
  }
}
