# Snowflake's service principal only exists in the tenant after admin consent, so the plural data
# source with ignore_missing returns an empty list instead of an error, and each role assignment
# below gates on a precondition (a postcondition here would also block destroy). Matched by client
# id, regexed out of the consent URL, because display names are not unique.
data "azuread_service_principals" "raw_storage" {
  client_ids     = [regex("client_id=([0-9a-fA-F-]+)", snowflake_external_volume.lakehouse.describe_output[0].storage_locations[0].azure_storage_location[0].azure_consent_url)[0]]
  ignore_missing = true
}

resource "azurerm_role_assignment" "raw_reader" {
  scope                = "${local.logs_account_id}/blobServices/default/containers/${var.logs_container_name}"
  role_definition_name = "Storage Blob Data Reader"
  # try(): the list is empty before consent, and destroy evaluates this expression too.
  principal_id                     = try(data.azuread_service_principals.raw_storage.service_principals[0].object_id, "00000000-0000-0000-0000-000000000000")
  skip_service_principal_aad_check = true # tolerate AAD replication lag right after consent

  lifecycle {
    precondition {
      condition     = length(data.azuread_service_principals.raw_storage.service_principals) > 0
      error_message = "Azure AD hasn't provisioned Snowflake's service principal yet. Grant admin consent, then re-run apply (if you already consented, Azure can take an hour or longer to create it; wait an hour or two and re-run): ${snowflake_external_volume.lakehouse.describe_output[0].storage_locations[0].azure_storage_location[0].azure_consent_url}"
    }
  }
}

# RBAC propagation is not instant: a fresh assignment can still 403 for a while. 180s is a
# conservative wait; re-running apply is idempotent if it is not enough.
resource "time_sleep" "raw_reader_propagation" {
  depends_on      = [azurerm_role_assignment.raw_reader]
  triggers        = { role_assignment_id = azurerm_role_assignment.raw_reader.id }
  create_duration = "180s"
}

# Snowflake writes Iceberg data and metadata files to the Iceberg container, so it needs
# Contributor there. Same service principal: consent is per Snowflake account/tenant, not per
# storage account.
resource "azurerm_role_assignment" "iceberg_contributor" {
  scope                            = azurerm_storage_container.iceberg.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = try(data.azuread_service_principals.raw_storage.service_principals[0].object_id, "00000000-0000-0000-0000-000000000000")
  skip_service_principal_aad_check = true # tolerate AAD replication lag right after consent

  lifecycle {
    precondition {
      condition     = length(data.azuread_service_principals.raw_storage.service_principals) > 0
      error_message = "Azure AD hasn't provisioned Snowflake's service principal yet. Grant admin consent, then re-run apply (if you already consented, Azure can take an hour or longer to create it; wait an hour or two and re-run): ${snowflake_external_volume.lakehouse.describe_output[0].storage_locations[0].azure_storage_location[0].azure_consent_url}"
    }
  }
}

# Snowflake's Iceberg write path uses a user delegation SAS, which needs generateUserDelegationKey.
# Storage Blob Delegator is the least-privileged built-in role with it, and it must be scoped at
# the storage account, not a container.
resource "azurerm_role_assignment" "storage_delegator" {
  scope                            = azurerm_storage_account.iceberg.id
  role_definition_name             = "Storage Blob Delegator"
  principal_id                     = try(data.azuread_service_principals.raw_storage.service_principals[0].object_id, "00000000-0000-0000-0000-000000000000")
  skip_service_principal_aad_check = true # tolerate AAD replication lag right after consent

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
