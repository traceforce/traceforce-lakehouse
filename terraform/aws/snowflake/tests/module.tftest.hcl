# The AWS Snowflake module's own logic, with mocked providers (no AWS or Snowflake access; every
# run applies to an in-memory state): names, IAM trust and policy scopes, the Iceberg bucket's
# TLS-only policy, stage names, and the region, bucket and warehouse checks.
#
#   cd terraform/aws/snowflake && terraform init -backend=false && terraform test
#
# Needs Terraform >= 1.7 (mock providers); the module itself still needs only 1.5.

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
  # Policy resources validate their JSON; the bucket ARN feeds the writer and bucket policies.
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
    defaults = { query_results = [{ WAREHOUSE = "COMPUTE_WH" }] }
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

run "names_and_urls" {
  assert {
    condition     = aws_s3_bucket.iceberg.bucket == "traceforce-lakehouse-iceberg-111122223333-us-east-2"
    error_message = "The Iceberg bucket name must be traceforce-lakehouse-iceberg-<account>-<region>."
  }
  assert {
    condition     = aws_iam_role.raw_reader.name == "traceforce-lakehouse-snowflake-raw" && aws_iam_role.iceberg_writer.name == "traceforce-lakehouse-snowflake-iceberg"
    error_message = "The role names must be traceforce-lakehouse-snowflake-raw and -iceberg."
  }
  assert {
    condition = toset(snowflake_storage_integration_aws.raw.storage_allowed_locations) == toset([
      "s3://acme-logs/traceforce/telemetry/", "s3://acme-logs/traceforce/_traceforce/lakehouse/exports/",
    ])
    error_message = "The integration must allow only the two TraceForce subtrees."
  }
  assert {
    condition     = snowflake_stage_external_s3.raw_telemetry.url == "s3://acme-logs/traceforce/telemetry/" && snowflake_stage_external_s3.raw_exports.url == "s3://acme-logs/traceforce/_traceforce/lakehouse/exports/"
    error_message = "Each stage must sit on its subtree."
  }
  assert {
    condition     = snowflake_storage_integration_aws.raw.storage_aws_role_arn == "arn:aws:iam::111122223333:role/traceforce-lakehouse-snowflake-raw" && snowflake_external_volume.lakehouse.storage_location[0].storage_aws_role_arn == "arn:aws:iam::111122223333:role/traceforce-lakehouse-snowflake-iceberg"
    error_message = "The integration and volume must name the composed role ARNs."
  }
  assert {
    condition     = snowflake_external_volume.lakehouse.storage_location[0].storage_base_url == "s3://traceforce-lakehouse-iceberg-111122223333-us-east-2/"
    error_message = "The volume must write to the module's Iceberg bucket."
  }
  assert {
    condition     = output.exports_root == "s3://acme-logs/traceforce/_traceforce/lakehouse/exports/"
    error_message = "exports_root must match the Athena module's value."
  }
}

# Each role trusts only its own Snowflake object, and each policy reaches only its own data.
run "iam_trust_and_policies" {
  assert {
    condition = (
      jsondecode(aws_iam_role.raw_reader.assume_role_policy).Statement[0].Principal.AWS == "arn:aws:iam::999988887777:user/sf" &&
      jsondecode(aws_iam_role.raw_reader.assume_role_policy).Statement[0].Condition.StringEquals["sts:ExternalId"] == "RAW_EXTERNAL_ID" &&
      jsondecode(aws_iam_role.iceberg_writer.assume_role_policy).Statement[0].Condition.StringEquals["sts:ExternalId"] == "ICEBERG_EXTERNAL_ID"
    )
    error_message = "Each role must trust the Snowflake IAM user with its own object's external id."
  }
  assert {
    condition = (
      toset(flatten([for s in jsondecode(aws_iam_role_policy.raw_reader.policy).Statement : s.Resource if s.Sid == "ReadRawAndExports"])) ==
      toset(["arn:aws:s3:::acme-logs/traceforce/telemetry/*", "arn:aws:s3:::acme-logs/traceforce/_traceforce/lakehouse/exports/*"])
    )
    error_message = "The read role may read objects only under the two subtrees."
  }
  assert {
    condition = (
      toset(one([for s in jsondecode(aws_iam_role_policy.raw_reader.policy).Statement : s.Condition.StringLike["s3:prefix"] if s.Sid == "ListPrefixOnly"])) ==
      toset(["traceforce/telemetry/*", "traceforce/_traceforce/lakehouse/exports/*"])
    )
    error_message = "The read role may list only inside the two subtrees."
  }
  assert {
    condition     = alltrue([for s in jsondecode(aws_iam_role_policy.raw_reader.policy).Statement : !anytrue([for a in flatten([s.Action]) : startswith(a, "s3:Put") || startswith(a, "s3:Delete")])])
    error_message = "The read role must not write or delete anything."
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.raw_reader.policy).Statement : s if s.Sid == "LogsBucketKey"]) == 0
    error_message = "Without logs_kms_key_arn there must be no KMS statement."
  }
  assert {
    condition = alltrue([for s in jsondecode(aws_iam_role_policy.iceberg_writer.policy).Statement :
    alltrue([for r in flatten([s.Resource]) : startswith(r, "arn:aws:s3:::traceforce-lakehouse-iceberg-111122223333-us-east-2")])])
    error_message = "The write role may reach only the Iceberg bucket."
  }
}

# The Iceberg bucket's policy denies plain HTTP and nothing else.
run "iceberg_bucket_denies_plain_http" {
  assert {
    condition = jsondecode(aws_s3_bucket_policy.iceberg.policy) == { Version = "2012-10-17", Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = ["arn:aws:s3:::traceforce-lakehouse-iceberg-111122223333-us-east-2", "arn:aws:s3:::traceforce-lakehouse-iceberg-111122223333-us-east-2/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }] }
    error_message = "The Iceberg bucket's policy must deny every non-TLS request to the bucket and its objects, and nothing else."
  }
}

# A recreated integration or volume brings a new external id: the trust changes in place, and the
# propagation wait must run again before anything reads or writes S3.
run "waits_follow_trust_changes" {
  assert {
    condition     = time_sleep.raw_reader_propagation.triggers["trust"] == aws_iam_role.raw_reader.assume_role_policy && time_sleep.iceberg_write_propagation.triggers["trust"] == aws_iam_role.iceberg_writer.assume_role_policy
    error_message = "Each propagation wait must be triggered by its role's trust policy."
  }
}

run "kms_key_adds_decrypt" {
  command = plan
  variables { logs_kms_key_arn = "arn:aws:kms:us-east-2:111122223333:key/abcd" }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.raw_reader.policy).Statement : s if s.Sid == "LogsBucketKey"]).Resource == "arn:aws:kms:us-east-2:111122223333:key/abcd"
    error_message = "logs_kms_key_arn must add a decrypt statement on that key."
  }
}

run "empty_prefix" {
  command = plan
  variables { logs_prefix = "" }

  assert {
    condition     = snowflake_stage_external_s3.raw_telemetry.url == "s3://acme-logs/telemetry/" && output.exports_root == "s3://acme-logs/_traceforce/lakehouse/exports/"
    error_message = "With no prefix the subtrees sit at the bucket root."
  }
  assert {
    condition = (
      toset(one([for s in jsondecode(aws_iam_role_policy.raw_reader.policy).Statement : s.Condition.StringLike["s3:prefix"] if s.Sid == "ListPrefixOnly"])) ==
      toset(["telemetry/*", "_traceforce/lakehouse/exports/*"])
    )
    error_message = "With no prefix the list scope starts at the subtrees."
  }
}

# A new bucket or prefix must rename the stages (Snowflake won't change a stage's URL while external
# tables use it), so the names carry a hash of logs_bucket and logs_prefix.
run "stage_names_follow_the_prefix" {
  command = plan

  assert {
    condition     = snowflake_stage_external_s3.raw_telemetry.name == "raw_landing_zone_telemetry_${substr(sha256("acme-logs/traceforce"), 0, 8)}" && snowflake_stage_external_s3.raw_exports.name == "raw_landing_zone_exports_${substr(sha256("acme-logs/traceforce"), 0, 8)}"
    error_message = "The stage names must end in a hash of logs_bucket and logs_prefix."
  }
}

run "stage_names_change_with_the_prefix" {
  command = plan
  variables { logs_prefix = "seed" }

  assert {
    condition     = snowflake_stage_external_s3.raw_telemetry.name == "raw_landing_zone_telemetry_${substr(sha256("acme-logs/seed"), 0, 8)}" && snowflake_stage_external_s3.raw_telemetry.name != "raw_landing_zone_telemetry_${substr(sha256("acme-logs/traceforce"), 0, 8)}"
    error_message = "A different logs_prefix must give different stage names."
  }
}

run "stage_names_change_with_the_bucket" {
  command = plan
  variables { logs_bucket = "other-logs" }

  assert {
    condition     = snowflake_stage_external_s3.raw_telemetry.name == "raw_landing_zone_telemetry_${substr(sha256("other-logs/traceforce"), 0, 8)}" && snowflake_stage_external_s3.raw_telemetry.name != "raw_landing_zone_telemetry_${substr(sha256("acme-logs/traceforce"), 0, 8)}"
    error_message = "A different logs_bucket with the same prefix must give different stage names."
  }
}

# --- Checks ---

run "region_group_prefix_accepted" {
  command = plan

  override_data {
    target = data.snowflake_current_account.this
    values = { region = "PUBLIC.AWS_US_EAST_2" }
  }
}

run "refuses_snowflake_in_another_aws_region" {
  command = plan

  override_data {
    target = data.snowflake_current_account.this
    values = { region = "AWS_US_WEST_2" }
  }
  expect_failures = [terraform_data.checks]
}

run "refuses_snowflake_on_azure" {
  command = plan

  override_data {
    target = data.snowflake_current_account.this
    values = { region = "AZURE_EASTUS2" }
  }
  expect_failures = [terraform_data.checks]
}

run "refuses_logs_bucket_in_another_region" {
  command = plan

  override_data {
    target = data.aws_s3_bucket.logs
    values = { bucket_region = "eu-west-1" }
  }
  expect_failures = [aws_s3_bucket.iceberg]
}

run "refuses_prefix_with_wildcard" {
  command = plan
  variables { logs_prefix = "trace*" }
  expect_failures = [var.logs_prefix]
}

run "refuses_prefix_with_slash" {
  command = plan
  variables { logs_prefix = "traceforce/" }
  expect_failures = [var.logs_prefix]
}

# The dashboards' token relay (dashboard_relay.tf): only with Snowflake's own sign-in, CORS for the
# console's origin only, forwarding to the account's token endpoint for the dashboards' client.
run "dashboard_relay" {
  variables {
    dashboard_sign_in = { console_origin = "https://app.example.com/", snowflake = {} }
  }
  override_resource {
    target = module.core.snowflake_execute.dashboards_lookup
    values = { query_results = [{ ORG = "ACME", ACCOUNT = "PROD_US", CLIENT_ID = "client+id/1=" }] }
  }
  override_resource {
    target = module.core.snowflake_execute.dashboards_roles
    values = { query_results = [
      { property = "ENABLED", property_value = "true" },
      { property = "ALLOWED_ROLES_LIST", property_value = "traceforce_lakehouse_reader" },
    ] }
  }
  # The provider validates ARNs even when mocked.
  override_resource {
    target = aws_iam_role.relay
    values = { arn = "arn:aws:iam::111122223333:role/traceforce-lakehouse-dashboard-relay" }
  }
  override_resource {
    target = aws_cloudwatch_log_group.relay
    values = { arn = "arn:aws:logs:us-east-2:111122223333:log-group:/aws/lambda/traceforce-lakehouse-dashboard-relay" }
  }

  assert {
    condition     = aws_lambda_function.relay[0].reserved_concurrent_executions == -1
    error_message = "No reserved concurrency unless relay_concurrency is set."
  }
  assert {
    condition = (aws_lambda_function_url.relay[0].authorization_type == "NONE"
      && aws_lambda_function_url.relay[0].cors[0].allow_origins == toset(["https://app.example.com"])
    && aws_lambda_function_url.relay[0].cors[0].allow_methods == toset(["POST"]))
    error_message = "A public function URL whose CORS lets only the console's origin POST."
  }
  assert {
    condition = (aws_lambda_function.relay[0].environment[0].variables["TOKEN_URL"] == "https://acme-prod-us.snowflakecomputing.com/oauth/token-request"
      && aws_lambda_function.relay[0].environment[0].variables["CLIENT_ID"] == "client+id/1="
    && aws_lambda_function.relay[0].environment[0].variables["ALLOWED_ORIGIN"] == "https://app.example.com")
    error_message = "The relay forwards to this account's token endpoint, for the dashboards' client, from the console's origin."
  }
  assert {
    condition = (aws_lambda_permission.relay_url[0].action == "lambda:InvokeFunctionUrl" && aws_lambda_permission.relay_url[0].function_url_auth_type == "NONE"
    && aws_lambda_permission.relay_invoke[0].action == "lambda:InvokeFunction" && aws_lambda_permission.relay_invoke[0].invoked_via_function_url == true)
    error_message = "Public invoke only through the function URL."
  }
  assert {
    condition = (jsondecode(aws_iam_role_policy.relay[0].policy).Statement[0].Action == ["logs:CreateLogStream", "logs:PutLogEvents"]
    && length(jsondecode(aws_iam_role_policy.relay[0].policy).Statement) == 1)
    error_message = "The relay's role may only write its own logs."
  }
  assert {
    condition     = output.dashboard_settings.snowflake.token_url == aws_lambda_function_url.relay[0].function_url && output.dashboard_settings.snowflake.client_id == "client+id/1="
    error_message = "dashboard_settings carries the relay's URL with the core's sign-in settings."
  }
}

run "relay_concurrency" {
  command = plan
  variables {
    dashboard_sign_in = { console_origin = "https://app.example.com", snowflake = { relay_concurrency = 5 } }
  }
  assert {
    condition     = aws_lambda_function.relay[0].reserved_concurrent_executions == 5
    error_message = "relay_concurrency must reserve that many concurrent executions for the relay."
  }
}

run "rejects_a_zero_relay_concurrency" {
  command = plan
  variables {
    dashboard_sign_in = { console_origin = "https://app.example.com", snowflake = { relay_concurrency = 0 } }
  }
  expect_failures = [var.dashboard_sign_in]
}

run "no_relay_for_an_identity_provider" {
  command = plan
  variables {
    dashboard_sign_in = { console_origin = "https://app.example.com", external = {
      provider = "entra", tenant_id = "11111111-2222-3333-4444-555555555555", audience = "api://traceforce-lakehouse"
    } }
  }

  assert {
    condition     = length(aws_lambda_function.relay) == 0 && length(aws_lambda_function_url.relay) == 0 && length(aws_iam_role.relay) == 0
    error_message = "Signing in through the company's identity provider needs no relay."
  }
}

run "no_relay_by_default" {
  command = plan

  assert {
    condition     = length(aws_lambda_function.relay) == 0 && output.dashboard_settings == null
    error_message = "Without dashboard_sign_in there is no relay and no settings output."
  }
}
