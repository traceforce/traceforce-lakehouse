# Derived Iceberg data lives in a module-owned bucket, NOT the customer's logs bucket. This keeps
# the connection SA off write/delete on the customer's raw logs, and means a lifecycle/Autoclass
# rule on the logs bucket can't reach (and corrupt) the Iceberg tables. Mirrors the AWS module's
# dedicated S3 Tables bucket. Co-located with the logs bucket so BigQuery can read it.
resource "google_storage_bucket" "iceberg" {
  name                        = "${local.project}-traceforce-lakehouse"
  location                    = data.google_storage_bucket.logs.location
  uniform_bucket_level_access = true
  force_destroy               = true # derived, re-ingestable data; let `terraform destroy` clean it up.
}
