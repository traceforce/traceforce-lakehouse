# Two serverless SQL warehouses, so reads and ingest scale (and are billed) separately: one for the
# scheduled ingest and mirror tasks, one for ad-hoc queries (engineers, Claude Code, the in-app
# dashboards). Each only wakes for a query or a task, so it stops after one minute idle (the
# provider default is 120); query_auto_stop_mins keeps the query warehouse up longer to avoid cold starts. Both carry the module's tags plus traceforce-warehouse = ingest / query,
# to tell them apart in usage and cost reports.

# Ingest: used only by the ingest service principal. One cluster: the tasks are scheduled, not bursty.
resource "databricks_sql_endpoint" "ingest" {
  name                      = "${local.name}-ingest"
  cluster_size              = var.ingest_warehouse_size
  max_num_clusters          = 1
  auto_stop_mins            = 1
  enable_serverless_compute = true  # set explicitly, as the provider docs recommend
  warehouse_type            = "PRO" # serverless requires PRO

  tags {
    dynamic "custom_tags" {
      for_each = merge(local.tags, { "traceforce-warehouse" = "ingest" })
      content {
        key   = custom_tags.key
        value = custom_tags.value
      }
    }
  }
}

# Who may use the ingest warehouse besides its owner (the deployer) and workspace admins. The only
# permissions resource on it (authoritative); readers aren't listed, so they can't affect it.
resource "databricks_permissions" "ingest_warehouse" {
  sql_endpoint_id = databricks_sql_endpoint.ingest.id

  access_control {
    service_principal_name = databricks_service_principal.ingest.application_id
    permission_level       = "CAN_USE"
  }
}

# Queries: the readers' warehouse (query_access.tf), and the one admins query on.
resource "databricks_sql_endpoint" "query" {
  name                      = local.name
  cluster_size              = var.query_warehouse_size
  max_num_clusters          = var.query_max_num_clusters
  auto_stop_mins            = var.query_auto_stop_mins
  enable_serverless_compute = true  # set explicitly, as the provider docs recommend
  warehouse_type            = "PRO" # serverless requires PRO

  tags {
    dynamic "custom_tags" {
      for_each = merge(local.tags, { "traceforce-warehouse" = "query" })
      content {
        key   = custom_tags.key
        value = custom_tags.value
      }
    }
  }
}

# Who may use the query warehouse besides its owner (the deployer) and workspace admins: the readers
# (query_access.tf). The only permissions resource on it (authoritative). databricks_permissions
# needs at least one entry, so there's none without readers.
resource "databricks_permissions" "query_warehouse" {
  count           = length(local.readers) > 0 ? 1 : 0
  sql_endpoint_id = databricks_sql_endpoint.query.id

  dynamic "access_control" {
    for_each = local.readers
    content {
      user_name              = access_control.value.kind == "user_name" ? access_control.value.name : null
      group_name             = access_control.value.kind == "group_name" ? access_control.value.name : null
      service_principal_name = access_control.value.kind == "service_principal_name" ? access_control.value.name : null
      permission_level       = "CAN_USE"
    }
  }
}
