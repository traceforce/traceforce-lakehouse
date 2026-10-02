# subscription_id / tenant_id / resource_group_name / storage_account_name are intentionally
# blank -- backend blocks can't reference variables, so real values come from a local,
# gitignored backend.hcl instead (see backend.hcl.example for the shape):
# `terraform init -backend-config=backend.hcl`. subscription_id/tenant_id matter here for the
# same reason as the azurerm/azuread providers in providers.tf: the backend initializes
# independently of the provider, so it needs its own explicit values rather than falling back
# to the Azure CLI's current context.
terraform {
  required_version = ">= 1.5"
  backend "azurerm" {
    subscription_id      = ""
    tenant_id            = ""
    resource_group_name  = ""
    storage_account_name = ""
    container_name       = "tfstate"
    key                  = "examples-azure.tfstate"
    use_azuread_auth     = true
  }
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = "~> 2.0"
    }
  }
}
