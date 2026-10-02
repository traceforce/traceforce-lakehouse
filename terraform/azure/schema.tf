# The column lists (agent_events + the 18 mirror tables) are defined once in ../schema and shared
# with tools/gen_skill_reference.py. This module consumes them and applies its own Snowflake side
# (raw.tf's external tables, tables.tf's Iceberg tables).
module "schema" {
  source = "../schema"
}
