# Enable the Google APIs this module needs, so a customer's `terraform apply` works in one
# shot (bigquerydatatransfer in particular is off by default). Idempotent: already-enabled
# APIs are a no-op. disable_on_destroy = false so `terraform destroy` never turns BigQuery
# off for the customer. Note: the applying identity needs permission to enable services
# (roles/serviceusage.serviceUsageAdmin, which Owner/Editor include); a tightly-scoped
# deploy SA must be granted it, or the customer enables these three APIs beforehand.
resource "google_project_service" "apis" {
  for_each = toset([
    "bigquery.googleapis.com",
    "bigqueryconnection.googleapis.com",
    "bigquerydatatransfer.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}
