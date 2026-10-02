# Minimal root configuration; mirrors the README. Replace the backend and values.
terraform {
  required_version = ">= 1.5"
  backend "azurerm" {
    subscription_id      = "00000000-0000-0000-0000-000000000000" # az account show --query id -o tsv
    tenant_id            = "00000000-0000-0000-0000-000000000000" # az account show --query tenantId -o tsv
    resource_group_name  = "acme-terraform-rg"
    storage_account_name = "acmetfstate"
    container_name       = "tfstate"
    key                  = "traceforce-lakehouse/terraform.tfstate"
    use_azuread_auth     = true
  }
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.9.0, < 5.0.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = ">= 2.19.0, < 3.0.0"
    }
  }
}

provider "azurerm" {
  subscription_id = "00000000-0000-0000-0000-000000000000" # az account show --query id -o tsv
  tenant_id       = "00000000-0000-0000-0000-000000000000" # az account show --query tenantId -o tsv
  features {}
}

# tenant_id pins this to the same directory as azurerm, rather than whichever tenant the
# Azure CLI's current context happens to default to.
provider "azuread" {
  tenant_id = "00000000-0000-0000-0000-000000000000" # az account show --query tenantId -o tsv
}

provider "snowflake" {
  organization_name = "acmeorg"        # Snowsight account selector, top-left
  account_name      = "acmeaccount"    # the account name, not the account locator
  user              = "acmedeployuser" # the Snowflake user Terraform authenticates as
  role              = "ACCOUNTADMIN"   # the module creates a resource monitor, integrations and an external volume, which only this role can
  authenticator     = "SNOWFLAKE_JWT"  # key-pair auth; this module always uses it, not a choice

  # private_key is the one real secret here -- deliberately not set above like the rest:
  # reads from SNOWFLAKE_PRIVATE_KEY in the environment, never hardcoded in this file.

  # preview_features_enabled is required: several resource types this module needs (external
  # tables, Iceberg tables, email notifications, alerts) are still preview-status in the
  # provider.
  preview_features_enabled = [
    "snowflake_external_table_resource",
    "snowflake_iceberg_table_resource",
    "snowflake_email_notification_integration_resource",
    "snowflake_alert_resource",
  ]
}

module "traceforce_lakehouse" {
  source = "../../terraform/azure" # customers: github.com/traceforce/traceforce-lakehouse//terraform/azure?ref=1.3.0

  # Must be globally unique across all of Azure (storage account names share one namespace
  # account-wide) and stable for the life of the deployment: changing it later destroys and
  # recreates the storage account, deleting the Iceberg table files.
  iceberg_storage_account_name = "acmetraceforcelakehouse"

  logs_storage_account_name = "acmetraceforcelogs"
  logs_resource_group_name  = "acme-logs-rg"
  logs_container_name       = "logs"
  logs_prefix               = "traceforce" # "" if TraceForce writes at the container root

  # warehouse_size             = "SMALL"       # default XSMALL; bump if ad-hoc queries feel slow or for a lookback_days catch-up
  # alarm_notification_email   = "jdoe@acme.com" # a verified Snowflake user's email, not a team address -- get notified when a scheduled Task fails
  # reader_users               = ["JDOE"]       # exact stored Snowflake usernames (uppercase unless created quoted) granted read-only access
  # credit_notification_users  = ["JDOE"]       # exact stored usernames with verified emails, emailed as credit usage climbs (the monitor never suspends the warehouse)
}

output "azure_consent_url" { value = module.traceforce_lakehouse.azure_consent_url }
output "reader_role_name" { value = module.traceforce_lakehouse.reader_role_name }
