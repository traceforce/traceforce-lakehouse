# Minimal root configuration; mirrors the README. Supply your own values via a local
# terraform.tfvars (gitignored -- see terraform.tfvars.example for the shape) to test
# against a real environment. Never commit terraform.tfvars.
module "traceforce_lakehouse" {
  source = "../../terraform/azure" # customers: github.com/traceforce/traceforce-lakehouse//terraform/azure?ref=1.3.0

  iceberg_storage_account_name = var.iceberg_storage_account_name

  logs_storage_account_name = var.logs_storage_account_name
  logs_resource_group_name  = var.logs_resource_group_name
  logs_container_name       = var.logs_container_name
  logs_prefix               = var.logs_prefix
  warehouse_size            = var.warehouse_size
  alarm_notification_email  = var.alarm_notification_email
  reader_users              = var.reader_users
}

output "azure_consent_url" {
  value = module.traceforce_lakehouse.azure_consent_url
}

output "reader_role_name" {
  value = module.traceforce_lakehouse.reader_role_name
}
