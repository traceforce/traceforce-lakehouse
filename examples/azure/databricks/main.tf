# Minimal root configuration; mirrors the README. Replace the backend and values.
terraform {
  required_version = ">= 1.5"
  backend "azurerm" {
    subscription_id      = "00000000-0000-0000-0000-000000000000" # az account show --query id -o tsv
    tenant_id            = "00000000-0000-0000-0000-000000000000" # az account show --query tenantId -o tsv
    resource_group_name  = "acme-terraform-rg"
    storage_account_name = "acmetfstate"
    container_name       = "tfstate"
    key                  = "traceforce-lakehouse-databricks/terraform.tfstate"
    use_azuread_auth     = true
  }
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.9.0, < 5.0.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = ">= 2.13.0, < 3.0.0"
    }
    databricks = {
      source  = "databricks/databricks"
      version = ">= 1.141.0, < 2.0.0"
    }
  }
}

provider "azurerm" {
  subscription_id = "00000000-0000-0000-0000-000000000000" # az account show --query id -o tsv
  tenant_id       = "00000000-0000-0000-0000-000000000000" # az account show --query tenantId -o tsv
  # Don't auto-register Azure resource providers: that needs subscription-level rights the
  # deployer may not have. Register the ones this module needs beforehand (README, "Before you start").
  resource_provider_registrations = "none"
  features {}
}

# Creates the serverless workspace (azurerm has no setting for it). Same subscription and tenant.
provider "azapi" {
  subscription_id = "00000000-0000-0000-0000-000000000000" # az account show --query id -o tsv
  tenant_id       = "00000000-0000-0000-0000-000000000000" # az account show --query tenantId -o tsv
}

# The workspace the module creates. Signs in with the same Azure identity as azurerm (the ARM_* variables).
provider "databricks" {
  host                        = module.traceforce_lakehouse.databricks_workspace_url
  azure_workspace_resource_id = module.traceforce_lakehouse.databricks_workspace_id
}

module "traceforce_lakehouse" {
  source = "../../../terraform/azure/databricks" # customers: github.com/traceforce/traceforce-lakehouse//terraform/azure/databricks?ref=1.7.3

  # Must be globally unique across all of Azure (storage account names share one namespace
  # account-wide) and stable for the life of the deployment: changing it later destroys and
  # recreates the storage account, deleting the Iceberg table files.
  iceberg_storage_account_name = "acmetraceforcelakehouse"

  # The Premium workspace this module creates in logs_resource_group_name. Stable for the life of
  # the deployment: changing it later replaces the workspace and everything in it.
  databricks_workspace_name = "acme-traceforce-lakehouse"

  logs_storage_account_name = "acmetraceforcelogs" # ADLS Gen2 (hierarchical namespace enabled)
  logs_resource_group_name  = "acme-logs-rg"
  logs_container_name       = "logs"
  logs_prefix               = "traceforce" # "" if TraceForce writes at the container root

  # ingest_warehouse_size    = "Small"                  # default 2X-Small; bump for a lookback_days catch-up
  # query_warehouse_size     = "Small"                  # default 2X-Small; bump if ad-hoc queries feel slow
  # query_max_num_clusters   = 2                        # default 1; raise if queries queue behind each other
  # query_auto_stop_mins     = 10                       # default 1; minutes idle before the query warehouse stops (fewer cold starts, more cost)
  # databricks_account_id    = "00000000-0000-0000-0000-000000000000" # optional; unset = read from the workspace (Public Beta data source). Account console, top-right menu.
  # alarm_notification_email = "jdoe@acme.com"          # get notified when a scheduled job fails or data goes stale
  # reader_user_names              = ["jdoe@acme.com"]    # read-only access: users (email)
  # reader_group_names             = ["security-team"]    # ... account groups
  # reader_service_principal_names = ["<application id>"] # ... service principals, e.g. a read-only identity for Claude Code
  # reader_can_view_jobs           = true                 # also let readers see the jobs' run history (default false)
  # lookback_days            = 7                        # default 3; raise only for a manual catch-up, then set it back
}

output "databricks_workspace_url" { value = module.traceforce_lakehouse.databricks_workspace_url }
output "databricks_workspace_id" { value = module.traceforce_lakehouse.databricks_workspace_id }
output "query_warehouse_id" { value = module.traceforce_lakehouse.query_warehouse_id }
