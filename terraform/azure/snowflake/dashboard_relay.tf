# Relay for the dashboards' Snowflake sign-in (dashboard_sign_in.tf). Browsers can't read
# Snowflake's OAuth token endpoint, so the dashboard posts the token request to this Function and it
# forwards the request to the account's endpoint (relay/, with the logic shared with AWS in
# terraform/snowflake/relay/relay.mjs). Tokens pass through the customer's own subscription only;
# it keeps nothing and logs only the grant type and status. Created only with
# dashboard_sign_in.snowflake set.
#
# Flex Consumption (Linux, pay per request, scales to zero), with a storage account of its own for
# the deployment package and the Functions host: never the logs or Iceberg account, whose data the
# Function must not reach. It reads that account with a user-assigned identity, not account keys,
# created and granted before the Function so the first deployment can already use it.

locals {
  relay_enabled = try(var.dashboard_sign_in.snowflake, null) != null
  # Globally unique names, derived so customers need no input: storage accounts take 3-24 lowercase
  # letters and digits; Function app names become <name>.azurewebsites.net.
  relay_suffix          = substr(sha1("${data.azurerm_client_config.current.subscription_id}/${var.logs_resource_group_name}/${var.iceberg_storage_account_name}"), 0, 12)
  relay_storage_account = "tflrelay${local.relay_suffix}"
  relay_app_name        = "${local.name}-relay-${local.relay_suffix}"
}

data "archive_file" "relay" {
  count       = local.relay_enabled ? 1 : 0
  type        = "zip"
  output_path = "${path.root}/.terraform/traceforce-lakehouse-dashboard-relay-azure.zip"
  source {
    filename = "host.json"
    content  = file("${path.module}/relay/host.json")
  }
  source {
    filename = "token/function.json"
    content  = file("${path.module}/relay/token/function.json")
  }
  source {
    filename = "token/index.mjs"
    content  = file("${path.module}/relay/token/index.mjs")
  }
  source {
    filename = "relay.mjs"
    content  = file("${path.module}/../../snowflake/relay/relay.mjs")
  }
}

resource "azurerm_storage_account" "relay" {
  count                           = local.relay_enabled ? 1 : 0
  name                            = local.relay_storage_account
  resource_group_name             = var.logs_resource_group_name
  location                        = local.logs_account_location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
}

resource "azurerm_storage_container" "relay" {
  count                 = local.relay_enabled ? 1 : 0
  name                  = "deployments"
  storage_account_id    = azurerm_storage_account.relay[0].id
  container_access_type = "private"
}

resource "azurerm_service_plan" "relay" {
  count               = local.relay_enabled ? 1 : 0
  name                = "${local.name}-relay"
  resource_group_name = var.logs_resource_group_name
  location            = local.logs_account_location
  os_type             = "Linux"
  sku_name            = "FC1"
}

resource "azurerm_user_assigned_identity" "relay" {
  count               = local.relay_enabled ? 1 : 0
  name                = "${local.name}-relay"
  resource_group_name = var.logs_resource_group_name
  location            = local.logs_account_location
}

# The Function's own storage account only: the deployment package and the host's leases.
resource "azurerm_role_assignment" "relay_storage" {
  count                = local.relay_enabled ? 1 : 0
  scope                = azurerm_storage_account.relay[0].id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_user_assigned_identity.relay[0].principal_id
}

resource "azurerm_function_app_flex_consumption" "relay" {
  count               = local.relay_enabled ? 1 : 0
  depends_on          = [azurerm_role_assignment.relay_storage]
  name                = local.relay_app_name
  resource_group_name = var.logs_resource_group_name
  location            = local.logs_account_location
  service_plan_id     = azurerm_service_plan.relay[0].id

  runtime_name                      = "node"
  runtime_version                   = "22"
  storage_container_type            = "blobContainer"
  storage_container_endpoint        = "${azurerm_storage_account.relay[0].primary_blob_endpoint}${azurerm_storage_container.relay[0].name}"
  storage_authentication_type       = "UserAssignedIdentity"
  storage_user_assigned_identity_id = azurerm_user_assigned_identity.relay[0].id
  instance_memory_in_mb             = 512
  maximum_instance_count            = 40
  https_only                        = true

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.relay[0].id]
  }

  app_settings = {
    TOKEN_URL                        = "${local.dashboard_account_url}/oauth/token-request"
    CLIENT_ID                        = try(local.dashboards_lookup["CLIENT_ID"], null)
    ALLOWED_ORIGIN                   = trimsuffix(var.dashboard_sign_in.console_origin, "/")
    AzureWebJobsStorage__accountName = azurerm_storage_account.relay[0].name
    AzureWebJobsStorage__credential  = "managedidentity"
    AzureWebJobsStorage__clientId    = azurerm_user_assigned_identity.relay[0].client_id
    AzureWebJobsSecretStorageType    = "files"
  }

  site_config {
    cors {
      allowed_origins = [trimsuffix(var.dashboard_sign_in.console_origin, "/")]
    }
  }
}

# Publishes the code with the Azure CLI, which deploying this module already needs signed in (README).
# Not the provider's zip_deploy_file: it posts to Kudu's api/zipdeploy, which Flex Consumption apps
# don't serve (404, hashicorp/terraform-provider-azurerm#29006, #29630); Flex takes code only through
# OneDeploy (api/publish), which az functionapp deployment source config-zip uses. Reruns when the
# code or the app changes.
resource "terraform_data" "relay_code" {
  count            = local.relay_enabled ? 1 : 0
  triggers_replace = [data.archive_file.relay[0].output_base64sha256, azurerm_function_app_flex_consumption.relay[0].id]

  provisioner "local-exec" {
    # Every value quoted: resource group names may contain parentheses (none may contain ').
    command = join(" ", [
      "az functionapp deployment source config-zip",
      "--subscription '${data.azurerm_client_config.current.subscription_id}'",
      "--resource-group '${var.logs_resource_group_name}'",
      "--name '${azurerm_function_app_flex_consumption.relay[0].name}'",
      "--src '${abspath(data.archive_file.relay[0].output_path)}'",
      "--output none",
    ])
  }
}
