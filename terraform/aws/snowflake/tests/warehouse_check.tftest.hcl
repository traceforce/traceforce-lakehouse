# The session-warehouse check (checks.tf) on its own: a separate file, because runs in one file
# share state and the check resource would already exist from an earlier run. Same mocks as
# module.tftest.hcl, except that Terraform's Snowflake session has no warehouse.
#
#   cd terraform/aws/snowflake && terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-2" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_s3_bucket" {
    defaults = { bucket_region = "us-east-2" }
  }
  # The policy resources validate their JSON, and the bucket ARN feeds the writer policy.
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::traceforce-lakehouse-iceberg-111122223333-us-east-2" }
  }
}

mock_provider "snowflake" {
  mock_data "snowflake_current_account" {
    defaults = { region = "AWS_US_EAST_2" }
  }
  # Each Snowflake object gets its own external id; the IAM user is one per account.
  mock_resource "snowflake_storage_integration_aws" {
    defaults = {
      describe_output = [{ iam_user_arn = "arn:aws:iam::999988887777:user/sf", external_id = "RAW_EXTERNAL_ID" }]
    }
  }
  mock_resource "snowflake_external_volume" {
    defaults = {
      describe_output = [{ storage_locations = [{ s3_storage_location = [{
        storage_aws_iam_user_arn = "arn:aws:iam::999988887777:user/sf", storage_aws_external_id = "ICEBERG_EXTERNAL_ID"
      }] }] }]
    }
  }
  mock_resource "snowflake_execute" {
    defaults = { query_results = [{ WAREHOUSE = "" }] }
  }
  # The provider validates identifier formats even when mocked, so the qualified names are realistic.
  mock_resource "snowflake_database" {
    defaults = { fully_qualified_name = "\"traceforce_lakehouse\"" }
  }
  mock_resource "snowflake_schema" {
    defaults = { fully_qualified_name = "\"traceforce_lakehouse\".\"traceforce\"" }
  }
  mock_resource "snowflake_account_role" {
    defaults = { fully_qualified_name = "\"traceforce_lakehouse_reader\"" }
  }
  mock_resource "snowflake_warehouse" {
    defaults = { fully_qualified_name = "\"traceforce_lakehouse\"" }
  }
  mock_resource "snowflake_stage_external_s3" {
    defaults = { fully_qualified_name = "\"traceforce_lakehouse\".\"traceforce\".\"stage\"" }
  }
  mock_resource "snowflake_external_table" {
    defaults = { fully_qualified_name = "\"traceforce_lakehouse\".\"traceforce\".\"external\"" }
  }
  mock_resource "snowflake_iceberg_table" {
    defaults = { fully_qualified_name = "\"traceforce_lakehouse\".\"traceforce\".\"iceberg\"" }
  }
}

mock_provider "time" {}

variables {
  logs_bucket = "acme-logs"
  logs_prefix = "traceforce"
}

run "refuses_session_without_warehouse" {
  expect_failures = [snowflake_execute.session_warehouse]
}
