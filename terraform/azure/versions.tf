# Child module: the caller's root configuration supplies the azurerm, azuread and snowflake
# providers (and therefore the Azure credentials and Snowflake connection) and the state
# backend. See README.
terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.9.0, < 5.0.0" # storage_account_id on azurerm_storage_container
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = ">= 2.19.0, < 3.0.0" # first release with snowflake_iceberg_table and non-preview Azure stage/integration resources
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
}
