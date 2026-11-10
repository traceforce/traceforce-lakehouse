# The freshness alert: every hour it reads the freshness view (tables.tf) and emails
# alarm_notification_email when a table is stale, i.e. runs succeed but no new data arrives, or a
# job has stopped. One email when it goes stale, a reminder every 24 hours while it stays stale,
# one when everything is fresh again. Run failures email from the jobs themselves (ingest.tf).
# Created only when alarm_notification_email is set, like the jobs' failure email.
locals {
  freshness_alert = var.alarm_notification_email == null ? 0 : 1
}

# The alert's recipient. A user_email subscription accepts only workspace users; a notification
# destination takes any address.
resource "databricks_notification_destination" "alarm" {
  count        = local.freshness_alert
  display_name = "${local.name}-alarm"
  config {
    email {
      addresses = [var.alarm_notification_email]
    }
  }
}

resource "databricks_alert_v2" "freshness" {
  count        = local.freshness_alert
  display_name = "${local.name}-freshness"
  # With the job SQL, not in the deployer's home folder. With /Workspace in front, as Databricks
  # returns it; without, the provider reports an inconsistent result.
  parent_path  = "/Workspace${databricks_directory.sql.path}"
  query_text   = "SELECT count_if(stale) AS stale_tables FROM ${databricks_sql_table.freshness.id} HAVING count(*) > 0"
  warehouse_id = databricks_sql_endpoint.ingest.id

  # Its own schedule, so it still fires when the jobs stop. :58, right after the hourly ingest (:57),
  # to check while the warehouse is likely still up from it (it stops after 1 idle minute).
  schedule = {
    quartz_cron_schedule = "0 58 * * * ?"
    timezone_id          = "UTC"
  }

  evaluation = {
    source              = { name = "stale_tables" }
    comparison_operator = "GREATER_THAN"
    threshold           = { value = { double_value = 0 } }
    # The view has a row per table, so no rows at all means it's broken.
    empty_result_state = "TRIGGERED"
    notification = {
      subscriptions     = [{ destination_id = databricks_notification_destination.alarm[0].id }]
      retrigger_seconds = 86400 # a daily reminder while anything stays stale
      notify_on_ok      = true
    }
  }

  # The query runs as the ingest principal, like the jobs. The alert's owner is whoever applies
  # (the provider can't set it).
  run_as = {
    service_principal_name = databricks_service_principal.ingest.application_id
  }

  # The deployer needs the User role on the principal to set run_as; the principal needs its
  # warehouse and schema access before the first check.
  depends_on = [
    databricks_access_control_rule_set.ingest,
    databricks_grant.ingest_catalog,
    databricks_grant.ingest_schema,
    databricks_permissions.ingest_warehouse,
  ]
}

# Running as the principal needs CAN_RUN on the alert: without it every check ends in ERROR (and
# emails so), and the query never runs.
resource "databricks_permissions" "freshness_alert" {
  count       = local.freshness_alert
  alert_v2_id = databricks_alert_v2.freshness[0].id

  access_control {
    service_principal_name = databricks_service_principal.ingest.application_id
    permission_level       = "CAN_RUN"
  }
}
