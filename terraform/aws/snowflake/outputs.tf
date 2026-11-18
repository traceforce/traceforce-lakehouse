output "reader_role_name" {
  description = "Snowflake role to GRANT to whoever should query the lakehouse, already quoted: GRANT ROLE <this> TO USER <them>. Not needed if you set reader_users or query_user_public_key."
  value       = module.core.reader_role_name
}

output "agent_events_fqn" {
  description = "Fully qualified table name for Snowflake SQL."
  value       = module.core.agent_events_fqn
}

output "exports_root" {
  description = "Where TraceForce's export job writes <table>/dt=YYYY-MM-DD/<HHMMSS>.jsonl.gz"
  value       = local.exports_root
}

output "query_user_name" {
  description = "Login name of the module-created read-only query user. Null unless query_user_public_key is set."
  value       = module.core.query_user_name
}

output "iceberg_bucket" {
  description = "The S3 bucket this module created for the Iceberg tables' files."
  value       = aws_s3_bucket.iceberg.id
}

output "snowflake_raw_role_arn" {
  description = "IAM role Snowflake assumes to read the logs bucket's two TraceForce subtrees."
  value       = aws_iam_role.raw_reader.arn
}

output "snowflake_iceberg_role_arn" {
  description = "IAM role Snowflake assumes to write the Iceberg bucket."
  value       = aws_iam_role.iceberg_writer.arn
}

output "query_warehouse_name" {
  description = "The warehouse readers run on (the skill, the dashboards)."
  value       = module.core.query_warehouse_name
}

output "dashboard_settings" {
  description = "Paste into the TraceForce console's Settings › Lakehouse to turn on the dashboards: terraform output -json dashboard_settings. Identifiers and URLs, not secrets. Null unless dashboard_sign_in is set."
  value = var.dashboard_sign_in == null ? null : merge(module.core.dashboard_sign_in, {
    snowflake = module.core.dashboard_sign_in.snowflake == null ? null : merge(module.core.dashboard_sign_in.snowflake, {
      token_url = aws_lambda_function_url.relay[0].function_url
    })
  })
}
