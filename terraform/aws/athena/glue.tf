# Athena reaches S3 Tables through Glue's federated catalog "s3tablescatalog". It is one
# account-level object per region shared by every S3 table bucket in the account; create it
# here unless the account already has it. The applying principal needs glue:CreateCatalog and
# glue:PassConnection for this step (README, Deploy). Destroying the module removes it again
# when the module created it.
resource "aws_glue_catalog" "s3tables" {
  count = var.create_glue_integration ? 1 : 0

  name        = "s3tablescatalog"
  description = "Federated catalog for Amazon S3 Tables (created by the TraceForce lakehouse module)"

  federated_catalog {
    identifier      = "arn:aws:s3tables:${local.region}:${local.account_id}:bucket/*"
    connection_name = "aws:s3tables"
  }

  create_database_default_permissions {
    permissions = ["ALL"]
    principal { data_lake_principal_identifier = "IAM_ALLOWED_PRINCIPALS" }
  }
  create_table_default_permissions {
    permissions = ["ALL"]
    principal { data_lake_principal_identifier = "IAM_ALLOWED_PRINCIPALS" }
  }

  allow_full_table_external_data_access = "True"
}

# Glue database for the module's own helper tables: the raw-object source table the
# ingest reads from, and the tables over TraceForce's TraceForce metadata exports.
resource "aws_glue_catalog_database" "lakehouse" {
  name        = "${replace(local.name, "-", "_")}_raw"
  description = "TraceForce lakehouse helper tables (raw activity objects, TraceForce metadata exports). Query agent_events in the S3 Tables catalog instead."
}
