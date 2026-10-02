provider "azurerm" {
  # v4 requires an explicit subscription (v3 used to infer it from the Azure CLI's active
  # subscription; v4 no longer does).
  subscription_id = var.azure_subscription_id
  tenant_id       = var.azure_tenant_id
  features {}
}

# tenant_id pins this to the same directory as azurerm, rather than whichever tenant the Azure
# CLI's current context happens to default to.
provider "azuread" {
  tenant_id = var.azure_tenant_id
}

provider "snowflake" {
  organization_name = var.snowflake_organization_name
  account_name      = var.snowflake_account_name
  user              = var.snowflake_user
  authenticator     = "SNOWFLAKE_JWT" # key-pair auth; this module always uses it, not a choice

  # private_key is the one real secret here -- deliberately NOT a variable (unlike the identity
  # args above): reads from SNOWFLAKE_PRIVATE_KEY in the environment, so it's never written into
  # a generated main.tf/tfvars by whatever produced this file (e.g. the TraceForce Settings UI).

  # snowflake_external_table / snowflake_iceberg_table / snowflake_email_notification_integration /
  # snowflake_alert are still preview-status resources in this provider version -- can't be set
  # via an env var, has to be listed here explicitly.
  preview_features_enabled = ["snowflake_external_table_resource", "snowflake_iceberg_table_resource", "snowflake_email_notification_integration_resource", "snowflake_alert_resource"]
}
