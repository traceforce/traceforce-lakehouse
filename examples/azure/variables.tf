# Generic, safe-to-commit defaults. Override with a local terraform.tfvars (gitignored --
# see terraform.tfvars.example) to test against a real environment.

# Azure provider identity -- not secrets, so plain variables rather than ARM_SUBSCRIPTION_ID/
# ARM_TENANT_ID env vars: which subscription and which Entra tenant to deploy into are
# identifying, not authenticating, information (Azure CLI/service-principal auth is what's
# actually secret, and that stays external to this file either way). A user signed into
# multiple tenants can't rely on the Azure CLI's current context matching the one that actually
# owns this storage account, so both are pinned explicitly rather than left to that fallback.
variable "azure_subscription_id" {
  type    = string
  default = "00000000-0000-0000-0000-000000000000" # az account show --query id -o tsv
}

variable "azure_tenant_id" {
  type    = string
  default = "00000000-0000-0000-0000-000000000000" # az account show --query tenantId -o tsv
}

# Snowflake provider identity -- not secrets (unlike SNOWFLAKE_PRIVATE_KEY, which stays an
# environment variable, never a Terraform variable or tfvars value): the organization/account
# name and the Terraform-deploying user are identifying, not authenticating, information, the
# same distinction AWS/GCP already draw (their provider blocks take a region/project, never
# credentials). Letting these be set as variables -- not just read from
# SNOWFLAKE_ORGANIZATION_NAME/SNOWFLAKE_ACCOUNT_NAME/SNOWFLAKE_USER in the environment -- is what
# lets a generated main.tf (e.g. the TraceForce Settings UI's Lakehouse tile) fill them in
# directly instead of asking the customer to export three more env vars alongside the one real
# secret.
variable "snowflake_organization_name" {
  type    = string
  default = "acmeorg" # Snowsight account selector, top-left -- the organization, not the account
}

variable "snowflake_account_name" {
  type    = string
  default = "acmeaccount" # the account name, not the account locator
}

variable "snowflake_user" {
  type    = string
  default = "TF_DEPLOY_USER" # the Snowflake user Terraform authenticates as (key-pair auth)
}

variable "logs_storage_account_name" {
  type    = string
  default = "acmetraceforcelogs" # storage account names: lowercase letters/numbers only, no hyphens
}

# Must be globally unique across all of Azure (storage account names share one namespace
# account-wide) and stable for the life of the deployment -- changing it later makes Terraform
# destroy and recreate the storage account, deleting the Iceberg table files.
variable "iceberg_storage_account_name" {
  type    = string
  default = "acmetraceforcelakehouse" # storage account names: lowercase letters/numbers only, no hyphens
}

variable "logs_resource_group_name" {
  type    = string
  default = "acme-logs-rg"
}

variable "logs_container_name" {
  type    = string
  default = "logs"
}

variable "logs_prefix" {
  type    = string
  default = "traceforce"
}

variable "warehouse_size" {
  type    = string
  default = "XSMALL"
}

variable "alarm_notification_email" {
  type    = string
  default = null
}

variable "reader_users" {
  type    = list(string)
  default = []
}
