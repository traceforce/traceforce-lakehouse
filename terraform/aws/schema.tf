# The column lists (agent_events + the 17 mirror tables) are defined once in ../schema and shared
# with the GCP module and tools/gen_skill_reference.py. This module consumes them and applies the
# AWS side (Iceberg types in s3tables.tf, Glue source columns + MERGE casts in exports.tf).
module "schema" {
  source = "../schema"
}
