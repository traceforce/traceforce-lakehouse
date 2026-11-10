# Child module: the caller's root configuration supplies the azurerm, azapi and databricks
# providers (and therefore the Azure credentials and the workspace connection) and the state
# backend. See README.
terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.9.0, < 5.0.0" # storage_account_id on azurerm_storage_container
    }
    azapi = {
      source  = "Azure/azapi"
      version = ">= 2.13.0, < 3.0.0" # the serverless workspace (computeMode, Microsoft.Databricks/workspaces@2026-01-01)
    }
    databricks = {
      source  = "databricks/databricks"
      version = ">= 1.141.0, < 2.0.0" # databricks_workspace_iam_service_principal_v2 takes name (account ID lookup; 1.141.0 replaced service_principal_id, which older releases require); file events off on external locations since 1.117.0
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
}
