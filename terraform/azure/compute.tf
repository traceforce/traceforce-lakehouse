# Notify-only on purpose: a monitor-triggered suspend would also stop the Tasks and the
# failure alert below until the monthly reset. The per-query runaway guard is the statement
# timeout snowflake_query.sh sets on its own session; a warehouse-level timeout would cut off
# the Tasks the same way. credit_quota is a starting guess, not a measured figure.
resource "snowflake_resource_monitor" "lakehouse" {
  name            = "traceforce_lakehouse"
  credit_quota    = 50
  frequency       = "MONTHLY"
  start_timestamp = "IMMEDIATELY"
  notify_triggers = [50, 80, 100]
  notify_users    = var.credit_notification_users
}

# Compute for ad-hoc queries and for the hourly ingest and 18 export-mirror Tasks (ingest.tf).
resource "snowflake_warehouse" "lakehouse" {
  name           = "traceforce_lakehouse"
  warehouse_size = upper(var.warehouse_size)
  # The warehouse only wakes for a Task or an ad-hoc query, so idle time is pure waste.
  auto_suspend     = 60
  auto_resume      = "true"
  resource_monitor = snowflake_resource_monitor.lakehouse.name
}

# A Task's error_integration cannot be EMAIL (queue types only), so the alert below polls
# TASK_HISTORY itself and sends through this integration. Snowflake only accepts verified
# Snowflake users as recipients.
resource "snowflake_email_notification_integration" "task_failures" {
  count              = var.alarm_notification_email == null ? 0 : 1
  name               = "traceforce_lakehouse_task_failures"
  enabled            = true
  allowed_recipients = [var.alarm_notification_email]
}

# SCHEDULED_TIME()/LAST_SUCCESSFUL_SCHEDULED_TIME() in the alert need SNOWFLAKE.ALERT_VIEWER on
# the role that owns the alert, i.e. the one applying this Terraform. Granted to CURRENT_ROLE()
# rather than PUBLIC: the provider's grant resources REVOKE on destroy, and revoking from PUBLIC
# would hit unrelated alerts in the account. snowflake_execute because CURRENT_ROLE() is only
# resolvable inside SQL; the role name is quoted (embedded quotes doubled) so a case-preserved
# name is not uppercase-folded. revert is a no-op: the grant is scoped to this one role.
resource "snowflake_execute" "alert_viewer" {
  count   = var.alarm_notification_email == null ? 0 : 1
  execute = <<-SQL
    BEGIN
      LET r STRING := CURRENT_ROLE();
      LET escaped_r STRING := REPLACE(r, '"', '""');
      EXECUTE IMMEDIATE 'GRANT DATABASE ROLE SNOWFLAKE.ALERT_VIEWER TO ROLE "' || escaped_r || '"';
      RETURN 'ok';
    END
  SQL
  revert  = "SELECT 1"
}

# Fires on any FAILED run in this module's database/schema, so it needs no per-Task wiring.
# Runs at :58 UTC, right after the :57 ingest, so it normally finds the warehouse already
# running instead of waking it to poll.
resource "snowflake_alert" "task_failures" {
  count     = var.alarm_notification_email == null ? 0 : 1
  name      = "traceforce_lakehouse_task_failures"
  database  = snowflake_database.lakehouse.name
  schema    = snowflake_schema.lakehouse.name
  warehouse = snowflake_warehouse.lakehouse.name
  enabled   = true

  depends_on = [snowflake_execute.alert_viewer]

  alert_schedule {
    cron {
      expression = "58 * * * *"
      time_zone  = "UTC"
    }
  }

  # DATABASE_NAME/SCHEMA_NAME scope TASK_HISTORY (otherwise account-wide) to this module's Tasks;
  # they are quoted identifiers inside the string literals because an unquoted name would
  # uppercase-fold and match nothing. RESULT_LIMIT 10000 so truncation cannot hide a failure.
  # START is 167 hours before CURRENT_TIMESTAMP() (7 days less an hour of margin): TASK_HISTORY
  # errors beyond 7 days, and a nominal SCHEDULED_TIME() can be late. Never narrow START to the
  # last check: it filters on scheduled time, not completion, so a long-running Task would drop
  # out before the COMPLETED_TIME filter below sees it. The COMPLETED_TIME window runs from the
  # last successful check (1 h fallback on the first run) up to this check's SCHEDULED_TIME(), so
  # a late check never re-reports what the previous one caught.
  condition = <<-SQL
    SELECT 1 FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
      SCHEDULED_TIME_RANGE_START => DATEADD('hour', -167, CURRENT_TIMESTAMP()),
      DATABASE_NAME => '"${snowflake_database.lakehouse.name}"',
      SCHEMA_NAME => '"${snowflake_schema.lakehouse.name}"',
      ERROR_ONLY => TRUE,
      RESULT_LIMIT => 10000
    ))
    WHERE COMPLETED_TIME >= COALESCE(SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME(),
                                      DATEADD('hour', -1, SNOWFLAKE.ALERT.SCHEDULED_TIME()))
      AND COMPLETED_TIME < SNOWFLAKE.ALERT.SCHEDULED_TIME()
  SQL

  # The integration name is a quoted identifier inside the string so it is not uppercase-folded;
  # replace() escapes any single quote in the email.
  action = "CALL SYSTEM$SEND_EMAIL('\"${snowflake_email_notification_integration.task_failures[0].name}\"', '${replace(var.alarm_notification_email, "'", "''")}', 'TraceForce lakehouse: a scheduled Task failed', 'One or more scheduled Tasks have failed since the last successful alert check. Check TASK_HISTORY for details.')"
}
