# Cost guardrail for the warehouse below. credit_quota is a conservative starting guess for a
# lightweight early-access warehouse (a few scheduled Task runs a day plus occasional ad-hoc
# queries), not a measured figure -- revisit once real usage data exists.
#
# Notify-only, deliberately no suspend_trigger/suspend_immediate_trigger: this warehouse is
# shared by the hourly ingest Task, all 18 export-mirror Tasks, the Task-failure alert above,
# and ad-hoc engineer/Claude Code queries, so a monitor-triggered suspend would silently stop
# all of those together -- including the alert that's supposed to say something broke -- until
# the monthly reset. The actual per-query runaway-cost guard is a statement timeout, scoped to
# ad-hoc queries specifically (skills/traceforce-lakehouse/scripts/snowflake_query.sh's own
# ALTER SESSION), not this warehouse: Snowflake only supports STATEMENT_TIMEOUT_IN_SECONDS at
# the account/user/warehouse/session level, never per-role, and warehouse-level would cut off
# the Tasks the same way a suspend would.
resource "snowflake_resource_monitor" "lakehouse" {
  name            = "traceforce_lakehouse"
  credit_quota    = 50
  frequency       = "MONTHLY"
  start_timestamp = "IMMEDIATELY"
  notify_triggers = [50, 80, 100]
  notify_users    = var.credit_notification_users
}

# Compute for ad-hoc queries from engineers or Claude Code, and for the hourly ingest and
# 18 export-mirror Tasks (ingest.tf) -- all 19 schedule against this same warehouse.
resource "snowflake_warehouse" "lakehouse" {
  name           = "traceforce_lakehouse"
  warehouse_size = upper(var.warehouse_size)
  # Aggressive on purpose: once Tasks exist, this warehouse will only wake for a scheduled Task
  # or an ad-hoc query, never a sustained workload, so idle compute between those is pure waste.
  # Real tuning needs actual query-pattern data this early-access module doesn't have yet --
  # start conservative.
  auto_suspend     = 60
  auto_resume      = "true"
  resource_monitor = snowflake_resource_monitor.lakehouse.name
}

# Task-failure email alerts. NOT wired via a Task's error_integration argument: that argument
# requires a QUEUE-type integration (AWS_SNS/AZURE_STORAGE_QUEUE/GCP_PUBSUB) and doesn't support
# EMAIL. The actual delivery mechanism is the alert below, which polls TASK_HISTORY itself and
# calls SYSTEM$SEND_EMAIL through this integration. Only created when alerts are configured.
resource "snowflake_email_notification_integration" "task_failures" {
  count              = var.alarm_notification_email == null ? 0 : 1
  name               = "traceforce_lakehouse_task_failures"
  enabled            = true
  allowed_recipients = [var.alarm_notification_email]
}

# SCHEDULED_TIME()/LAST_SUCCESSFUL_SCHEDULED_TIME() below (both alert-context-only functions)
# need the caller's role to hold this SNOWFLAKE-provided database role. Granted directly to
# CURRENT_ROLE() -- the role applying this Terraform, which owns/evaluates the alert below under
# Snowflake's owner's-rights model -- not to PUBLIC: confirmed live that Snowflake's own grant
# resources REVOKE on destroy, so granting to the shared PUBLIC role would mean disabling
# alarm_notification_email (or destroying this module) could silently revoke access from some
# unrelated alert elsewhere in the account that came to depend on the same grant later. Snowflake
#'s own docs example for this grant also targets a specific role, never PUBLIC.
#
# snowflake_execute (not snowflake_grant_database_role) because CURRENT_ROLE() has to be resolved
# dynamically inside the SQL itself -- there's no preview-free way to read "the role this
# provider authenticates as" as a plain Terraform value. revert is a harmless no-op, not a
# REVOKE: confirmed live this grant is scoped to one specific role now, so there's no reason to
# claw it back on destroy.
#
# CURRENT_ROLE() is quoted (as a literal identifier, with any embedded " doubled) before being
# concatenated into the dynamic GRANT statement, not interpolated bare -- confirmed live that
# Snowflake supports quoted, case-preserved role names (this module's own reader role is one),
# and concatenating one of those in unquoted uppercase-folds it, so the GRANT targets a role
# that doesn't exist and the actual applying role never receives ALERT_VIEWER.
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

# Task-failure email alert -- checks for any FAILED task run in this module's own database/
# schema, not specific task names, so it doesn't need to know about each of the 19 Tasks
# (ingest.tf) individually. Runs at :58 UTC, a minute after the hourly ingest Task is scheduled,
# so the check normally finds the warehouse already running (auto_suspend is 60 s) instead of
# waking it just to poll (the provider requires a warehouse).
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

  # DATABASE_NAME/SCHEMA_NAME scope this to the module's own 19 Tasks -- TASK_HISTORY is
  # account-wide without them, confirmed live, so an unrelated Task failing elsewhere in the
  # account would otherwise compete for the same RESULT_LIMIT. Embedded double quotes force an
  # exact-case (quoted identifier) match: confirmed live that the plain lowercase name alone
  # resolves as an unquoted identifier instead, uppercase-folds, and matches nothing, since this
  # module's database/schema are case-preserved lowercase.
  #
  # RESULT_LIMIT => 10000 (vs. the 100 default) so ERROR_ONLY's own truncation can't hide a
  # failure past 100 runs in the 7-day window -- now that this is scoped to just this module's own
  # Tasks, 19 Tasks x hourly x 7 days is at most ~3200 runs, so this cap is never actually reached.
  #
  # SCHEDULED_TIME_RANGE_START is the retained 7-day window less an hour of margin: TASK_HISTORY
  # errors on a start more than 7 days back, and whether it compares against this statement's
  # CURRENT_TIMESTAMP() or a slightly later clock read is undocumented, so sitting exactly on the
  # boundary could fail the condition. It is based on
  # CURRENT_TIMESTAMP() rather than SNOWFLAKE.ALERT.SCHEDULED_TIME() -- confirmed live,
  # TASK_HISTORY's 7-day limit is checked against actual wall-clock time regardless of what
  # SCHEDULED_TIME_RANGE_END is given, so basing START on the alert's own (possibly delayed)
  # nominal schedule risks a hard "Cannot retrieve data from more than 7 days ago" error on a
  # sufficiently late evaluation. It's never narrowed further (e.g. to
  # LAST_SUCCESSFUL_SCHEDULED_TIME()) either: SCHEDULED_TIME_RANGE_START filters on when a run was
  # *scheduled*, not when it *completed*, so a narrower cutoff can make TASK_HISTORY exclude a
  # long-running task before the COMPLETED_TIME filter below ever sees it. All real filtering is
  # done by that WHERE clause instead.
  #
  # Lower bound: the alert's last successful check (not a fixed window), since a failure can
  # complete well after its task was scheduled. Falls back to 1 hour on the alert's first-ever
  # evaluation (LAST_SUCCESSFUL_SCHEDULED_TIME() is NULL then).
  # Upper bound: this check's own SCHEDULED_TIME() (exclusive). Both SCHEDULED_TIME() and
  # LAST_SUCCESSFUL_SCHEDULED_TIME() report nominal, not actual, run time, so a delayed check
  # would otherwise re-report a failure the previous check already caught. This bounds every check
  # to its own nominal slot, trading at most one extra cycle of delay for never duplicating.
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

  # SYSTEM$SEND_EMAIL's integration-name argument does its own identifier resolution: an
  # unquoted-style plain string gets uppercase-folded the same as any unquoted reference to a
  # Terraform-created (case-preserved lowercase) object, so it's embedded as a quoted identifier
  # here, not a bare name. replace(...) doubles any single quote in the email before it's
  # embedded in this SQL string literal -- the correct SQL escape regardless of the variable's
  # own validation already rejecting one.
  # "since the last successful check", not "in the last hour": the condition above can report a
  # failure older than an hour when a previous check was itself delayed or failed, and a static
  # "last hour" claim would hand recipients a false incident timeline in exactly that case.
  action = "CALL SYSTEM$SEND_EMAIL('\"${snowflake_email_notification_integration.task_failures[0].name}\"', '${replace(var.alarm_notification_email, "'", "''")}', 'TraceForce lakehouse: a scheduled Task failed', 'One or more scheduled Tasks have failed since the last successful alert check. Check TASK_HISTORY for details.')"
}
