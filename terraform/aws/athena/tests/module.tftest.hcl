# The AWS (Athena) module's results bucket policy, with a mocked provider (no AWS access; the run
# applies to an in-memory state).
#
#   cd terraform/aws/athena && terraform init -backend=false && terraform test
#
# Needs Terraform >= 1.7 (mock providers); the module itself still needs only 1.5.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-2" }
  }
  mock_data "aws_s3_bucket" {
    defaults = { bucket_region = "us-east-2" }
  }
  # A fixed ARN, so the assertion can name it.
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::traceforce-lakehouse-results-111122223333-us-east-2" }
  }
  # The provider validates ARN arguments even when mocked.
  mock_resource "aws_s3tables_table_bucket" {
    defaults = { arn = "arn:aws:s3tables:us-east-2:111122223333:bucket/traceforce-lakehouse" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/traceforce-lakehouse-mock" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-2:111122223333:log-group:traceforce-lakehouse-mock" }
  }
  mock_resource "aws_sfn_state_machine" {
    defaults = { arn = "arn:aws:states:us-east-2:111122223333:stateMachine:traceforce-lakehouse-mock" }
  }
}

variables {
  logs_bucket = "acme-logs"
  logs_prefix = "traceforce"
}

# The results bucket's policy denies plain HTTP and nothing else.
run "results_bucket_denies_plain_http" {
  assert {
    condition = jsondecode(aws_s3_bucket_policy.results.policy) == { Version = "2012-10-17", Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = ["arn:aws:s3:::traceforce-lakehouse-results-111122223333-us-east-2", "arn:aws:s3:::traceforce-lakehouse-results-111122223333-us-east-2/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }] }
    error_message = "The results bucket's policy must deny every non-TLS request to the bucket and its objects, and nothing else."
  }
  assert {
    condition     = aws_s3_bucket_policy.results.bucket == aws_s3_bucket.results.id
    error_message = "The policy must be on the module's results bucket."
  }
}
