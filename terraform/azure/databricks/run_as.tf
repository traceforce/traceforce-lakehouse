# The identity the scheduled jobs run as, so ingestion doesn't depend on the deployer's account.
# A workspace admin can create a Databricks-managed service principal (it's added to the account
# automatically) and becomes its Service Principal Manager; setting it as a job's run_as also
# needs the Service Principal User role, which the deployer grants themselves below. No account
# admin is needed.
resource "databricks_service_principal" "ingest" {
  display_name = "${local.name}-ingest"
  # Set explicitly: workspaces no longer grant default entitlements through the users group.
  workspace_access      = true
  databricks_sql_access = true
}

# The identity running terraform apply, which gets the Service Principal User role below.
# Keep the depends_on: this data source has no inputs, so Terraform would otherwise read it while
# planning. On a first deploy the workspace doesn't exist yet, so the databricks provider has no
# host to connect to and the plan fails ("cannot configure default credentials"). Depending on
# the workspace makes Terraform wait until the workspace exists. Side effect: a plan that changes the
# workspace also shows the rule set below as changing; the apply leaves it unchanged.
data "databricks_current_user" "deployer" {
  depends_on = [azapi_resource.workspace]
}

# The rule set's name needs the account ID, which Databricks shows only in the account console
# (account admins). Unset, it's read from the workspace with this data source (Public Beta);
# databricks_account_id overrides it.
data "databricks_workspace_iam_service_principal_v2" "ingest" {
  count = var.databricks_account_id == null ? 1 : 0
  name  = "service-principals/${databricks_service_principal.ingest.id}" # the provider's resource name form since 1.141.0
}

locals {
  # The rule set's principals: the identity running apply, plus the additional_deployer_* inputs as
  # Databricks ACL principal IDs. User names and application IDs are in lowercase (variables.tf), as
  # Databricks stores them; group names are case-sensitive and kept as typed.
  deployer_principals = distinct(concat(
    [data.databricks_current_user.deployer.acl_principal_id],
    [for n in var.additional_deployer_user_names : "users/${n}"],
    [for n in var.additional_deployer_group_names : "groups/${n}"],
    [for n in var.additional_deployer_service_principal_names : "servicePrincipals/${n}"],
  ))

  uuid_pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"

  # null (not an error) if neither gives one, so the rule set's precondition explains it.
  databricks_account_id = try(coalesce(var.databricks_account_id, terraform_data.databricks_account_id.output), null)
}

# The account ID as first read, kept: the lookup is re-read whenever the ingest principal changes,
# which would make the rule set's name unknown at plan and replace the rule set. The delete removes
# the deployer's Manager role, so the re-create fails and locks the deployer out.
resource "terraform_data" "databricks_account_id" {
  input = try(coalesce(var.databricks_account_id, one(data.databricks_workspace_iam_service_principal_v2.ingest[*].account_id)), null)

  lifecycle {
    ignore_changes = [input]
  }
}

# Who may act as the service principal: the deployer and the additional_deployer_* inputs, each with
# User (to set and update the jobs' run_as) and Manager (so they can apply again). Authoritative: it
# replaces every role on the principal, so roles granted by hand are removed on the next apply.
resource "databricks_access_control_rule_set" "ingest" {
  name = "accounts/${local.databricks_account_id}/servicePrincipals/${databricks_service_principal.ingest.application_id}/ruleSets/default"

  lifecycle {
    precondition {
      condition     = can(regex(local.uuid_pattern, local.databricks_account_id))
      error_message = "The account ID lookup (the Public Beta databricks_workspace_iam_service_principal_v2 data source) returned no valid ID. Set databricks_account_id: account console, top-right user menu (account admins only)."
    }
    # A different account ID would rename, and so replace, the rule set (see terraform_data above).
    precondition {
      condition     = var.databricks_account_id == null || terraform_data.databricks_account_id.output == null || var.databricks_account_id == terraform_data.databricks_account_id.output
      error_message = "databricks_account_id (${coalesce(var.databricks_account_id, "unset")}) differs from the account ID this deployment was created with (${coalesce(terraform_data.databricks_account_id.output, "unknown")}). It can't change: fix it or unset it. If the first apply failed because that ID was wrong, run terraform destroy, then apply again with the correct ID."
    }
  }

  grant_rules {
    principals = local.deployer_principals
    role       = "roles/servicePrincipal.user"
  }
  grant_rules {
    principals = local.deployer_principals
    role       = "roles/servicePrincipal.manager"
  }
}

# What the jobs read and write. databricks_grant is authoritative for this one principal only, so
# grants to other principals are left alone.
resource "databricks_grant" "ingest_raw" {
  external_location = databricks_external_location.raw.id
  principal         = databricks_service_principal.ingest.application_id
  privileges        = ["READ_FILES"]
}

resource "databricks_grant" "ingest_catalog" {
  catalog    = databricks_catalog.lakehouse.name
  principal  = databricks_service_principal.ingest.application_id
  privileges = ["USE_CATALOG"]
}

resource "databricks_grant" "ingest_schema" {
  schema     = databricks_schema.lakehouse.id
  principal  = databricks_service_principal.ingest.application_id
  privileges = ["USE_SCHEMA", "SELECT", "MODIFY"]
}

# The jobs' SQL files.
resource "databricks_permissions" "sql_folder" {
  directory_path = databricks_directory.sql.path

  access_control {
    service_principal_name = databricks_service_principal.ingest.application_id
    permission_level       = "CAN_READ"
  }
}
