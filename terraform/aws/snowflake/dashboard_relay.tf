# Relay for the dashboards' Snowflake sign-in (core: dashboard_sign_in.tf). Browsers can't read
# Snowflake's OAuth token endpoint, so the dashboard posts the token request to this function's URL
# and it forwards the request to the account's endpoint (relay/index.mjs; the logic, shared with
# Azure, is terraform/snowflake/relay/relay.mjs). Tokens pass through the customer's own AWS account
# only; it keeps nothing and logs only the grant type and status. Created only with
# dashboard_sign_in.snowflake set.

locals {
  relay_enabled = try(var.dashboard_sign_in.snowflake, null) != null
  relay_name    = "${local.name}-dashboard-relay"
}

data "archive_file" "relay" {
  count = local.relay_enabled ? 1 : 0
  type  = "zip"
  source {
    filename = "index.mjs"
    content  = file("${path.module}/relay/index.mjs")
  }
  source {
    filename = "relay.mjs"
    content  = file("${path.module}/../../snowflake/relay/relay.mjs")
  }
  output_path = "${path.root}/.terraform/traceforce-lakehouse-dashboard-relay.zip"
}

resource "aws_iam_role" "relay" {
  count = local.relay_enabled ? 1 : 0
  name  = local.relay_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Its own log group, and nothing else.
resource "aws_iam_role_policy" "relay" {
  count = local.relay_enabled ? 1 : 0
  name  = local.relay_name
  role  = aws_iam_role.relay[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.relay[0].arn}:*"
    }]
  })
}

resource "aws_cloudwatch_log_group" "relay" {
  count             = local.relay_enabled ? 1 : 0
  name              = "/aws/lambda/${local.relay_name}"
  retention_in_days = 30
}

resource "aws_lambda_function" "relay" {
  count            = local.relay_enabled ? 1 : 0
  depends_on       = [aws_iam_role_policy.relay]
  function_name    = local.relay_name
  description      = "TraceForce UI dashboards: forwards Snowflake OAuth token requests (browsers can't call the endpoint)."
  role             = aws_iam_role.relay[0].arn
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  handler          = "index.handler"
  filename         = data.archive_file.relay[0].output_path
  source_code_hash = data.archive_file.relay[0].output_base64sha256
  memory_size      = 128
  timeout          = 10
  # Optional cap, so a flood of requests to the public URL can't use up the account's shared Lambda
  # concurrency. Unset by default: AWS lets a function reserve at most the account's unreserved
  # concurrency minus 100, so an account with a limit of 100 or less can't reserve any. (-1 = none.)
  reserved_concurrent_executions = coalesce(try(var.dashboard_sign_in.snowflake.relay_concurrency, null), -1)

  environment {
    variables = {
      TOKEN_URL      = "${module.core.dashboard_sign_in.account_url}/oauth/token-request"
      CLIENT_ID      = module.core.dashboard_sign_in.snowflake.client_id
      ALLOWED_ORIGIN = trimsuffix(var.dashboard_sign_in.console_origin, "/")
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.relay[0].name
  }
}

# Public: the browser calls it before the viewer has any AWS identity. It can only forward the
# dashboards' token requests to this account, which anyone can send to Snowflake directly anyway.
resource "aws_lambda_function_url" "relay" {
  count              = local.relay_enabled ? 1 : 0
  function_name      = aws_lambda_function.relay[0].function_name
  authorization_type = "NONE"
  # After both permissions: see the comment on them.
  depends_on = [aws_lambda_permission.relay_url, aws_lambda_permission.relay_invoke]

  cors {
    allow_origins = [trimsuffix(var.dashboard_sign_in.console_origin, "/")]
    allow_methods = ["POST"]
    allow_headers = ["content-type"]
    max_age       = 3600
  }
}

# A public function URL needs both permissions (lambda:InvokeFunction only through the URL). Since AWS provider
# #44858, aws_lambda_function_url with authorization_type NONE also adds these two statements, with the same ids,
# and ignores "statement id already exists". aws_lambda_permission doesn't: it retries that error until its create
# timeout. So the URL waits for these (depends_on there), never the other way round.
resource "aws_lambda_permission" "relay_url" {
  count                  = local.relay_enabled ? 1 : 0
  statement_id           = "FunctionURLAllowPublicAccess"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.relay[0].function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "relay_invoke" {
  count                    = local.relay_enabled ? 1 : 0
  statement_id             = "FunctionURLAllowInvokeAction"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.relay[0].function_name
  principal                = "*"
  invoked_via_function_url = true
}
