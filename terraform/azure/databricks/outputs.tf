output "databricks_workspace_id" {
  description = "Azure resource ID of the workspace the module creates. The root's databricks provider takes it as azure_workspace_resource_id."
  value       = azapi_resource.workspace.id
}

output "databricks_workspace_url" {
  description = "The workspace URL (adb-<id>.<n>.azuredatabricks.net). The root's databricks provider takes it as host."
  value       = azapi_resource.workspace.output.properties.workspaceUrl
}

output "ingest_job_id" {
  description = "ID of the hourly ingest job: to start a catch-up run (Run now, or the Jobs API's run-now) or read its run history."
  value       = databricks_job.scheduled["ingest"].id
}

output "mirror_job_id" {
  description = "ID of the daily mirror job: to start a run by hand or read its run history."
  value       = databricks_job.scheduled["mirror"].id
}

output "ingest_service_principal_application_id" {
  description = "Application ID of the service principal the jobs run as (traceforce-lakehouse-ingest)."
  value       = databricks_service_principal.ingest.application_id
}

output "query_warehouse_id" {
  description = "ID of the SQL warehouse for ad-hoc queries (readers, Claude Code, the in-app dashboards)."
  value       = databricks_sql_endpoint.query.id
}

output "query_warehouse_http_path" {
  description = "HTTP path of the query warehouse, for ODBC/JDBC drivers and BI tools (with databricks_workspace_url as the server hostname)."
  value       = databricks_sql_endpoint.query.odbc_params[0].path
}

output "agent_events_fqn" {
  description = "Fully qualified table name for Databricks SQL."
  value       = "${databricks_sql_table.agent_events.catalog_name}.${databricks_sql_table.agent_events.schema_name}.${databricks_sql_table.agent_events.name}"
}

output "exports_root" {
  description = "Where TraceForce's export job writes <table>/dt=YYYY-MM-DD/<HHMMSS>.jsonl.gz"
  value       = local.exports_root
}
