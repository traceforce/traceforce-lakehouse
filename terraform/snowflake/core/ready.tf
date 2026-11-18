# depends_on can't name an input variable, so each readiness input goes through a resource: the
# external tables wait for read access to the raw logs, the Iceberg tables for write access to the
# Iceberg storage.
resource "terraform_data" "raw_ready" {
  input = var.raw_ready
}

resource "terraform_data" "iceberg_ready" {
  input = var.iceberg_ready
}
