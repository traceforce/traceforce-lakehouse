# Child module shared by the Snowflake modules (terraform/azure/snowflake once it switches over,
# terraform/aws/snowflake). It holds everything that doesn't depend on the cloud: the database,
# warehouse, Iceberg and external tables, Tasks, alerts and reader access. The calling module
# creates the storage, its access, the external volume and the stages, and passes them in. The
# snowflake provider comes from the caller.
terraform {
  required_version = ">= 1.5"
  required_providers {
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = ">= 2.19.0, < 3.0.0" # first release with snowflake_iceberg_table
    }
  }
}
