# The column lists (agent_events + the 18 mirror tables) are defined once in ../schema and shared
# with the AWS and GCP modules and tools/gen_skill_reference.py; raw.tf and tables.tf apply the
# Snowflake side.
module "schema" {
  source = "../schema"
}
