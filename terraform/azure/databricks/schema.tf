# The column lists (agent_events + the mirror tables) are defined once in ../../schema and shared
# with the other cloud modules and tools/gen_skill_reference.py.
module "schema" {
  source = "../../schema"
}
