# The column lists (agent_events + the 18 mirror tables) are defined once in ../schema and shared
# with the AWS module and tools/gen_skill_reference.py. This module consumes them and applies the
# BigQuery side (the bq_type map in locals.tf turns the source types into BigQuery types).
module "schema" {
  source = "../schema"
}
