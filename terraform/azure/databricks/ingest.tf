# Two scheduled jobs on the ingest SQL warehouse (compute.tf), run as the ingest service principal:
#   hourly at :57 UTC  -> flatten raw telemetry from the last lookback_days upload days (and tomorrow's) into agent_events
#   daily 12:30 UTC    -> refresh each metadata mirror from its newest export snapshot
# Same schedule as the Snowflake module's Tasks. Each job runs SQL files from the workspace (a SQL
# file task is the only SQL task type that fully respects run_as); every file is one BEGIN ... END
# script with no session settings. No retries: the next run catches up, and the anti-join and the
# newest-snapshot rule make a re-run exact.

# The job SQL, rendered by render_sql: the same module renders it for the golden test, so both fill
# in the templates (sql/) the same way. One mirror file per table: the newest snapshot pinned once,
# then one atomic MERGE that upserts and deletes (sql/mirror_export.sql.tftpl). Every script ends
# by logging its run to _ingest_runs, which the freshness view reads (tables.tf).
module "sql" {
  source             = "./render_sql"
  agent_events_table = databricks_sql_table.agent_events.id
  mirror_tables      = { for t, tbl in databricks_sql_table.export : t => tbl.id }
  runs_table         = local.runs_table
  run_log_since      = formatdate("YYYY-MM-DD hh:mm:ss", time_static.run_log.rfc3339)
  logs_root          = "${local.container_root}${local.prefix_slash}"
  lookback_days      = var.lookback_days
}

locals {
  # A top-level folder, never under /Shared: every workspace user has CAN_MANAGE on /Shared and its
  # children inherit it, so anyone could edit the SQL the jobs run as the ingest service principal.
  # A top-level folder inherits only the workspace admins' access; the principal gets CAN_READ
  # (run_as.tf).
  sql_folder = "/${local.name}"

  failure_emails = var.alarm_notification_email == null ? [] : [var.alarm_notification_email]

  # One SQL file per task, named after the task (as the Snowflake module's Tasks).
  sql_files = merge(
    { ingest_agent_events = module.sql.ingest_sql },
    { for t, sql in module.sql.mirror_sql : "mirror_export_${t}" => sql },
  )

  # The two jobs; everything else about them is the same (databricks_job.scheduled below).
  jobs = {
    ingest = {
      cron            = "0 57 * * * ?"
      timeout_seconds = 14400 # 4 h, as the Snowflake Task, so a lookback_days catch-up can finish
      tasks           = ["ingest_agent_events"]
    }
    mirror = {
      cron = "0 30 12 * * ?"
      # 1 h, as Snowflake's default task timeout: a stuck run fails and emails instead of holding
      # the only run slot (and skipping the next days) until the warehouse's 2-day statement timeout.
      timeout_seconds = 3600
      # One independent task per mirror table (no depends_on between them), so a broken table
      # fails alone with its own error.
      tasks = [for t in keys(module.sql.mirror_sql) : "mirror_export_${t}"]
    }
  }
}

resource "databricks_directory" "sql" {
  path = local.sql_folder
}

resource "databricks_workspace_file" "sql" {
  for_each       = local.sql_files
  path           = "${databricks_directory.sql.path}/${each.key}.sql"
  content_base64 = base64encode(each.value)
}

resource "databricks_job" "scheduled" {
  for_each            = local.jobs
  name                = "${local.name}-${each.key}"
  max_concurrent_runs = 1
  timeout_seconds     = each.value.timeout_seconds

  # A run that starts while the previous one is still going is skipped, not queued (as Snowflake's
  # allow_overlapping_execution = false): the next run catches up.
  queue {
    enabled = false
  }

  # A skipped run (the previous one still going) isn't emailed as a failure: the next run catches
  # up, and a stuck run fails at the timeout and emails then. AWS ends an overlapping run as
  # succeeded, and Snowflake's alert reads failed runs only.
  notification_settings {
    no_alert_for_skipped_runs = true
  }

  schedule {
    quartz_cron_expression = each.value.cron
    timezone_id            = "UTC"
  }

  dynamic "task" {
    for_each = each.value.tasks
    content {
      task_key = task.value
      sql_task {
        warehouse_id = databricks_sql_endpoint.ingest.id
        file {
          path   = databricks_workspace_file.sql[task.value].path
          source = "WORKSPACE"
        }
        # The run ID the script logs (:run_id).
        parameters = { run_id = "{{job.run_id}}" }
      }
    }
  }

  run_as {
    service_principal_name = databricks_service_principal.ingest.application_id
  }

  dynamic "email_notifications" {
    for_each = length(local.failure_emails) > 0 ? [1] : []
    content {
      on_failure = local.failure_emails
    }
  }

  # The deployer needs the User role on the principal to set run_as, and the principal needs its
  # grants before the first run.
  depends_on = [
    databricks_access_control_rule_set.ingest,
    databricks_grant.ingest_raw,
    databricks_grant.ingest_catalog,
    databricks_grant.ingest_schema,
    databricks_permissions.ingest_warehouse,
    databricks_permissions.sql_folder,
    databricks_sql_table.ingest_runs, # the run log the scripts write, named rather than referenced
  ]
}

# The jobs are owned by the ingest service principal, not by whoever ran terraform apply: a job's
# owner defaults to its creator, and jobs owned by a deleted user fail. Workspace admins keep
# CAN_MANAGE. Job permissions are authoritative, so these are the only ones on each job; the
# readers get CAN_VIEW (run history; query_access.tf) only when reader_can_view_jobs is true.
resource "databricks_permissions" "job" {
  for_each = databricks_job.scheduled
  job_id   = each.value.id

  access_control {
    service_principal_name = databricks_service_principal.ingest.application_id
    permission_level       = "IS_OWNER"
  }

  # Readers (query_access.tf).
  dynamic "access_control" {
    for_each = var.reader_can_view_jobs ? local.readers : {}
    content {
      user_name              = access_control.value.kind == "user_name" ? access_control.value.name : null
      group_name             = access_control.value.kind == "group_name" ? access_control.value.name : null
      service_principal_name = access_control.value.kind == "service_principal_name" ? access_control.value.name : null
      permission_level       = "CAN_VIEW"
    }
  }
}
