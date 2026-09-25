# Child module: the caller's root configuration supplies the azurerm, azuread and snowflake
# providers (and therefore the subscription/tenant credentials and Snowflake connection) and
# the state backend. See README.
terraform {
  required_version = ">= 1.5"
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
