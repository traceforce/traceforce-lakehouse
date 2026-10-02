# Resolves the storage integration's generated service principal by client id into the object id
# azurerm_role_assignment needs. This only exists in the tenant after admin consent is granted,
# so it isn't there yet on a fresh apply -- the plural data source (not the singular one) plus
# ignore_missing lets that come back as an empty list instead of a hard provider error, checked
# below via a precondition on each role assignment rather than a postcondition here: a data
# source's postcondition runs on every plan that reads it, destroy included, which would block
# tearing down an unconsented deployment; a resource precondition is only a warning on destroy
# (the pre-destroy refresh), so gating on the role assignments instead only blocks create/update.
#
# Matched by client id, not display name: neither snowflake_external_volume nor
# snowflake_storage_integration_azure exposes a raw client_id attribute, only the consent URL
# string it's embedded in, so it's pulled out with regex() here. A client id is 1:1 with a
# service principal within a tenant, unlike a display name, which isn't guaranteed unique.
data "azuread_service_principals" "raw_storage" {
  client_ids     = [regex("client_id=([0-9a-fA-F-]+)", snowflake_external_volume.lakehouse.describe_output[0].storage_locations[0].azure_storage_location[0].azure_consent_url)[0]]
  ignore_missing = true
}

resource "azurerm_role_assignment" "raw_reader" {
  scope                = "${local.logs_account_id}/blobServices/default/containers/${var.logs_container_name}"
  role_definition_name = "Storage Blob Data Reader"
  # try(): before admin consent the lookup is an empty list, and the precondition below is what
  # stops create/update with the consent URL. Destroy evaluates this expression too, with
  # preconditions downgraded to warnings, so an unguarded [0] would fail it with "Invalid index".
  principal_id = try(data.azuread_service_principals.raw_storage.service_principals[0].object_id, "00000000-0000-0000-0000-000000000000")
  # Defensive: a brief propagation delay right after consent is plausible even though this
  # isn't the same kind of genuine authorization gap the underlying resource itself has.
  skip_service_principal_aad_check = true

  lifecycle {
    precondition {
      condition     = length(data.azuread_service_principals.raw_storage.service_principals) > 0
      error_message = "Azure AD hasn't provisioned Snowflake's service principal yet. Grant admin consent, then re-run apply (if you already consented, Azure can take an hour or longer to create it; wait an hour or two and re-run): ${snowflake_external_volume.lakehouse.describe_output[0].storage_locations[0].azure_storage_location[0].azure_consent_url}"
    }
  }
}

# The role assignment object can report "Creation complete" while the permission isn't actually
# effective yet (raw.tf's external tables 403 with AuthorizationPermissionMismatch otherwise).
# Microsoft doesn't publish a hard number for RBAC propagation; 180s is a conservative starting
# point, not a proven minimum -- re-running apply is idempotent if a create still races past it.
resource "time_sleep" "raw_reader_propagation" {
  depends_on      = [azurerm_role_assignment.raw_reader]
  triggers        = { role_assignment_id = azurerm_role_assignment.raw_reader.id }
  create_duration = "180s"
}

# Write-side counterpart to the Reader role above: creating an Iceberg table needs Contributor
# on the Iceberg container (Snowflake writes Parquet/metadata files there), the same
# AuthorizationPermissionMismatch shape as raw.tf's read path. Same service principal, different
# storage account/role -- reuses the lookup above rather than duplicating it: the admin-consent
# this service principal needed is scoped to the Snowflake account/tenant pair (see
# external_volume.tf), not to any particular storage account, so granting it access to the new,
# module-owned Iceberg account here needs no separate consent step.
resource "azurerm_role_assignment" "iceberg_contributor" {
  scope                            = azurerm_storage_container.iceberg.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = try(data.azuread_service_principals.raw_storage.service_principals[0].object_id, "00000000-0000-0000-0000-000000000000")
  skip_service_principal_aad_check = true

  lifecycle {
    precondition {
      condition     = length(data.azuread_service_principals.raw_storage.service_principals) > 0
      error_message = "Azure AD hasn't provisioned Snowflake's service principal yet. Grant admin consent, then re-run apply (if you already consented, Azure can take an hour or longer to create it; wait an hour or two and re-run): ${snowflake_external_volume.lakehouse.describe_output[0].storage_locations[0].azure_storage_location[0].azure_consent_url}"
    }
  }
}

# Contributor alone still fails creating an Iceberg table: Snowflake's Iceberg write path uses a
# user delegation SAS, which needs the generateUserDelegationKey action -- a separate action
# Contributor doesn't include. Storage Blob Delegator is the least-privileged built-in role that
# has it, and per Microsoft's docs it must be scoped at the storage account (or higher), never a
# container -- "Get User Delegation Key" acts at the account level. Scoped to the Iceberg
# account (storage.tf), not the logs account: delegation is only needed for the Iceberg write
# path, which now lives in its own account.
resource "azurerm_role_assignment" "storage_delegator" {
  scope                            = azurerm_storage_account.iceberg.id
  role_definition_name             = "Storage Blob Delegator"
  principal_id                     = try(data.azuread_service_principals.raw_storage.service_principals[0].object_id, "00000000-0000-0000-0000-000000000000")
  skip_service_principal_aad_check = true

  lifecycle {
    precondition {
      condition     = length(data.azuread_service_principals.raw_storage.service_principals) > 0
      error_message = "Azure AD hasn't provisioned Snowflake's service principal yet. Grant admin consent, then re-run apply (if you already consented, Azure can take an hour or longer to create it; wait an hour or two and re-run): ${snowflake_external_volume.lakehouse.describe_output[0].storage_locations[0].azure_storage_location[0].azure_consent_url}"
    }
  }
}

resource "time_sleep" "iceberg_write_propagation" {
  depends_on = [azurerm_role_assignment.iceberg_contributor, azurerm_role_assignment.storage_delegator]
  triggers = {
    contributor_id = azurerm_role_assignment.iceberg_contributor.id
    delegator_id   = azurerm_role_assignment.storage_delegator.id
  }
  create_duration = "180s"
}
