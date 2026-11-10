# Read-only access for the reader_* inputs (people, Claude Code, the in-app dashboards), each as its
# own identity; the module creates no query identity or credential. Readers get USE CATALOG, and USE
# SCHEMA + SELECT on the lakehouse schema (current and future tables), CAN_USE on the query warehouse
# (compute.tf) and, when reader_can_view_jobs is true, CAN_VIEW on the two jobs (ingest.tf). Each
# also needs the workspace entitlement Databricks SQL access, which the module doesn't set
# (databricks_entitlements replaces a principal's whole list). The identity running apply and the ingest service principal can't be readers:
# Databricks refuses the permission lists with either in them. The lookups below reject both, at plan
# or, on a first deploy, during apply before any reader grant or permission is written.

locals {
  # { key = { kind, name as Databricks stores it } }. Granted under the stored name: a grant to
  # another spelling is applied but reported as failed. Keyed by the entry, known at plan even on a
  # first deploy. User names and application IDs must be in lowercase (variables.tf), as Databricks
  # stores them: a pending workspace change makes Terraform read the lookups during apply, and the
  # name it plans with is then the entry as typed, so any other spelling would replace the grants
  # (revoking them during the apply). Group names are case-sensitive and kept.
  readers = merge(
    { for n in distinct(var.reader_user_names) : n => { kind = "user_name", name = data.databricks_user.reader[n].user_name } },
    { for n in distinct(var.reader_group_names) : n => { kind = "group_name", name = data.databricks_group.reader[n].display_name } },
    { for n in distinct(var.reader_service_principal_names) : n => { kind = "service_principal_name", name = data.databricks_service_principal.reader[n].application_id } },
  )
}

# Each reader is looked up before anything is granted. A lookup fails, naming the entry, when the
# principal isn't in the workspace (at plan, or during apply on a first deploy, read once the
# workspace exists). Databricks rejects a whole permissions list if one principal is unknown, and
# the jobs' lists also hold the ingest principal's ownership. The grants and permissions are built
# from local.readers, which reads every lookup, so none is written on a failure. Not caught: a
# workspace-local group is found, but Unity Catalog grants only to account groups, so its grants
# fail at apply. The lookups also reject the identity running apply and the ingest service
# principal, in any letter case.
data "databricks_user" "reader" {
  for_each   = toset(var.reader_user_names)
  user_name  = each.key
  depends_on = [azapi_resource.workspace]

  lifecycle {
    postcondition {
      condition     = lower(self.user_name) != lower(data.databricks_current_user.deployer.user_name)
      error_message = "reader_user_names: ${each.key} is the identity running terraform apply, which already has full access; Databricks won't let the module downgrade it to read-only. Remove it."
    }
  }
}

data "databricks_group" "reader" {
  for_each     = toset(var.reader_group_names)
  display_name = each.key
  depends_on   = [azapi_resource.workspace]
}

data "databricks_service_principal" "reader" {
  for_each       = toset(var.reader_service_principal_names)
  application_id = each.key
  depends_on     = [azapi_resource.workspace]

  lifecycle {
    postcondition {
      condition     = !contains([lower(data.databricks_current_user.deployer.user_name), lower(databricks_service_principal.ingest.application_id)], lower(self.application_id))
      error_message = "reader_service_principal_names: ${each.key} is the identity running terraform apply or the ingest service principal, which already have full access; Databricks won't let the module downgrade them to read-only. Remove it."
    }
  }
}

# databricks_grant is authoritative for one principal only, so the ingest service principal's grants
# (run_as.tf) are left alone; databricks_grants would replace them.
resource "databricks_grant" "reader_catalog" {
  for_each   = local.readers
  catalog    = databricks_catalog.lakehouse.name
  principal  = each.value.name
  privileges = ["USE_CATALOG"]
}

resource "databricks_grant" "reader_schema" {
  for_each   = local.readers
  schema     = databricks_schema.lakehouse.id
  principal  = each.value.name
  privileges = ["USE_SCHEMA", "SELECT"]
}
