# Child module: the caller's root configuration supplies the aws provider (its region must be the
# logs bucket's region), the snowflake provider (an account on AWS in that same region) and the
# state backend. Creating the Iceberg tables needs a warehouse in Terraform's session, before this
# module's warehouse exists: the deploy user's default warehouse, or the provider's warehouse
# argument. See README, "AWS (Snowflake)".
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.44.0"
    }
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = ">= 2.19.0, < 3.0.0" # first release with snowflake_iceberg_table; also has the S3 integration, S3 stage and external volume this module uses
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
}
