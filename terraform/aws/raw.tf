# The ingest's SOURCE: a Glue table over the raw gzipped OTLP-JSON objects scout writes under
#   <root>telemetry/agent=<AGENT_IDENTITY_*>/dt=<YYYYMMDD>/...
# Each object is one compact JSON document on a single line, so the table is a single string
# column and Athena's JSON functions unnest it. Nobody queries this table directly; it exists so
# the scheduled INSERT can read the objects in place.
#
# Two projected partitions, so no catalog partitions are ever registered and nothing is listed
# beyond the folders a run reads: `agent` is INJECTED -- the state machine discovers the
# agent=... folders with one S3 listing and runs the ingest once per agent (Athena requires the
# value in the query) -- and `dt` is the upload day. No agent list lives in this module: a new
# agent identity is ingested on the next hourly run. Browser captures and pre-telemetry/ layouts
# live under conversations/ and are never touched. Requires the scout release that writes the
# telemetry/ layout; objects written by older collectors are not read.
resource "aws_glue_catalog_table" "raw_telemetry" {
  name          = "raw_telemetry"
  database_name = aws_glue_catalog_database.lakehouse.name
  table_type    = "EXTERNAL_TABLE"
  description   = "TraceForce raw activity objects, one OTLP-JSON document per row. Ingest source only; query agent_events instead."

  parameters = {
    EXTERNAL                      = "TRUE"
    "projection.enabled"          = "true"
    "projection.agent.type"       = "injected"
    "projection.dt.type"          = "date"
    "projection.dt.format"        = "yyyyMMdd"
    "projection.dt.range"         = "${local.day_layout_since},NOW+1DAYS"
    "projection.dt.interval"      = "1"
    "projection.dt.interval.unit" = "DAYS"
    "storage.location.template"   = "${local.raw_root}agent=$${agent}/dt=$${dt}/"
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
