# The existing landing-zone storage account TraceForce already writes agent activity logs to
# (see the Storage Provider integration assumption in variables.tf). Looked up (not created)
# so this module never touches the customer's own storage account.
data "azurerm_storage_account" "logs" {
  name                = var.logs_storage_account_name
  resource_group_name = var.logs_resource_group_name
}

# Module-owned storage account for Iceberg table data -- deliberately never the customer's
# existing logs account. A lifecycle rule there ("delete blobs after 90 days" is common for
# logs) would otherwise also delete live Iceberg table files once they age past that threshold:
# Azure lifecycle filters can only include a path prefix, never exclude one, so a container
# living inside that same account has no way to opt out of a policy already written before this
# module existed. Matches GCP's module-owned bucket; AWS uses a dedicated table bucket.
#
# name is var.iceberg_storage_account_name directly -- required, no computed default (variables.tf).
resource "azurerm_storage_account" "iceberg" {
  name                = var.iceberg_storage_account_name
  resource_group_name = var.logs_resource_group_name
  # Same region as the logs account: avoids cross-region egress on every write, and keeps this
  # data in the same residency as the logs it's derived from (see README's "Before you start").
  location = data.azurerm_storage_account.logs.location
  # Conservative defaults for a lightweight early-access workload, not measured figures --
  # revisit once real usage data exists (same posture as compute.tf's credit_quota).
  account_tier             = "Standard"
  account_replication_type = "LRS"

  # Explicit, not relied on as the provider's own default: Snowflake's storage integration
  # reaches this account over the public internet (no VNet/private-endpoint setup here), so
  # network access has to stay open -- but no anonymous/public blob access is ever allowed.
  # Every request still goes through the RBAC role assignments below (role_assignments.tf).
  public_network_access_enabled   = true
  allow_nested_items_to_be_public = false
}

# storage_account_id (Resource Manager API) rather than the deprecated storage_account_name
# (Data Plane API) is the modern, non-deprecated way to create a container.
resource "azurerm_storage_container" "iceberg" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.iceberg.id
  container_access_type = "private" # explicit, not relied on as the provider's own default
}
