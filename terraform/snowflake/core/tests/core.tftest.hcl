# The core's wiring, optional resources and input checks, with a mocked snowflake provider (no
# Snowflake account needed; every run is a plan):
#
#   cd terraform/snowflake/core && terraform init -backend=false && terraform test
#
# Needs Terraform >= 1.7 (mock providers); the module itself still needs only 1.5.

mock_provider "snowflake" {}

variables {
  external_volume_name    = "traceforce_lakehouse"
  telemetry_location      = "@\"traceforce_lakehouse\".\"traceforce\".\"raw\"/pfx/telemetry/"
  exports_location_prefix = "@\"traceforce_lakehouse\".\"traceforce\".\"raw\"/pfx/_traceforce/lakehouse/exports/"
  raw_ready               = "raw-ready"
  iceberg_ready           = "iceberg-ready"
}

# The calling module's locations and external volume reach the right tables, and every export
# table has both its external source and its Iceberg mirror.
run "wiring" {
  command = plan

  assert {
    condition     = snowflake_external_table.raw_telemetry.location == var.telemetry_location
    error_message = "raw_telemetry must read telemetry_location."
  }
  assert {
    condition = alltrue([
      for t, et in snowflake_external_table.export_src : et.location == "${var.exports_location_prefix}${t}/"
    ])
    error_message = "Each export source must read exports_location_prefix + <table>/."
  }
  assert {
    condition     = length(snowflake_external_table.export_src) > 0 && keys(snowflake_external_table.export_src) == keys(snowflake_iceberg_table.export)
    error_message = "Every export table needs both an external source and an Iceberg mirror."
  }
  assert {
    condition = alltrue(concat(
      [snowflake_iceberg_table.agent_events.external_volume == var.external_volume_name],
      [for t in snowflake_iceberg_table.export : t.external_volume == var.external_volume_name],
    ))
    error_message = "Every Iceberg table must use external_volume_name."
  }
  assert {
    condition     = snowflake_warehouse.lakehouse.warehouse_size == "XSMALL"
    error_message = "The default warehouse size must be XSMALL."
  }
}

# Readers get their own warehouse: suspended until used, on the same resource monitor, with USAGE
# for the reader role. The Tasks stay on the ingest warehouse. The overrides give the query warehouse's
# and the ingest warehouse's computed fully qualified names values, so the plan knows which one the
# grant names.
run "query_warehouse" {
  command = plan

  override_resource {
    target          = snowflake_warehouse.query
    override_during = plan
    values          = { fully_qualified_name = "\"traceforce_lakehouse_query\"" }
  }
  override_resource {
    target          = snowflake_warehouse.lakehouse
    override_during = plan
    values          = { fully_qualified_name = "\"traceforce_lakehouse\"" }
  }

  assert {
    condition = (
      snowflake_warehouse.query.name == "traceforce_lakehouse_query" &&
      snowflake_warehouse.query.warehouse_size == "XSMALL" &&
      snowflake_warehouse.query.auto_suspend == 60 &&
      snowflake_warehouse.query.initially_suspended == true &&
      snowflake_warehouse.query.resource_monitor == snowflake_resource_monitor.lakehouse.name &&
      output.query_warehouse_name == "traceforce_lakehouse_query"
    )
    error_message = "The query warehouse must be traceforce_lakehouse_query: XSMALL, 60 s auto-suspend, created suspended, on the module's resource monitor."
  }
  assert {
    condition = (
      snowflake_grant_privileges_to_account_role.reader_query_warehouse.privileges == toset(["USAGE"]) &&
      one(snowflake_grant_privileges_to_account_role.reader_query_warehouse.on_account_object).object_type == "WAREHOUSE" &&
      one(snowflake_grant_privileges_to_account_role.reader_query_warehouse.on_account_object).object_name == snowflake_warehouse.query.fully_qualified_name
    )
    error_message = "The reader role must get USAGE on the query warehouse."
  }
  assert {
    condition = alltrue(concat(
      [snowflake_task.ingest.warehouse == snowflake_warehouse.lakehouse.name],
      [for t in snowflake_task.export_mirror : t.warehouse == snowflake_warehouse.lakehouse.name],
    ))
    error_message = "The ingest and mirror Tasks must stay on the ingest warehouse."
  }
}

# Defaults: no alert, no query user, no grants to existing users, no credit recipients.
run "optional_resources_off_by_default" {
  command = plan

  assert {
    condition = (
      length(snowflake_email_notification_integration.task_failures) == 0 &&
      length(snowflake_execute.alert_viewer) == 0 &&
      length(snowflake_alert.task_failures) == 0
    )
    error_message = "Without alarm_notification_email there must be no email integration, grant or alert."
  }
  assert {
    condition     = length(snowflake_service_user.query) == 0 && length(snowflake_grant_account_role.query_user) == 0
    error_message = "Without query_user_public_key there must be no query user."
  }
  assert {
    condition     = length(snowflake_grant_account_role.reader) == 0
    error_message = "Without reader_users there must be no reader grants."
  }
  assert {
    condition     = output.query_user_name == null
    error_message = "query_user_name must be null without a query user."
  }
}

run "optional_resources_on" {
  command = plan

  variables {
    warehouse_size            = "small"
    query_warehouse_size      = "medium"
    alarm_notification_email  = "ops@example.com"
    query_user_public_key     = "QUJDRA=="
    reader_users              = ["JDOE", "ASMITH"]
    credit_notification_users = ["JDOE"]
  }

  assert {
    condition = (
      length(snowflake_email_notification_integration.task_failures) == 1 &&
      length(snowflake_execute.alert_viewer) == 1 &&
      length(snowflake_alert.task_failures) == 1 &&
      strcontains(snowflake_alert.task_failures[0].action, "'ops@example.com'")
    )
    error_message = "alarm_notification_email must create the integration, grant and alert, emailing that address."
  }
  assert {
    condition = (
      length(snowflake_service_user.query) == 1 &&
      snowflake_service_user.query[0].rsa_public_key == "QUJDRA==" &&
      snowflake_service_user.query[0].default_secondary_roles_option == "NONE" &&
      length(snowflake_grant_account_role.query_user) == 1 &&
      output.query_user_name == "traceforce_lakehouse_query" &&
      snowflake_service_user.query[0].default_warehouse == snowflake_warehouse.query.name
    )
    error_message = "query_user_public_key must create the read-only query user, on the query warehouse, and grant it the reader role."
  }
  assert {
    condition     = toset(keys(snowflake_grant_account_role.reader)) == toset(["JDOE", "ASMITH"])
    error_message = "Each reader_users name must get one reader grant."
  }
  assert {
    condition     = snowflake_resource_monitor.lakehouse.notify_users == toset(["JDOE"])
    error_message = "credit_notification_users must be the resource monitor's recipients."
  }
  assert {
    condition     = snowflake_warehouse.lakehouse.warehouse_size == "SMALL" && snowflake_warehouse.query.warehouse_size == "MEDIUM"
    error_message = "warehouse_size and query_warehouse_size must each size their own warehouse, uppercased."
  }
}

# --- Input checks ---

run "rejects_exports_prefix_without_slash" {
  command = plan
  variables { exports_location_prefix = "@stage/exports" }
  expect_failures = [var.exports_location_prefix]
}

run "rejects_email_with_quote" {
  command = plan
  variables { alarm_notification_email = "o'brien@example.com" }
  expect_failures = [var.alarm_notification_email]
}

run "rejects_zero_lookback_days" {
  command = plan
  variables { lookback_days = 0 }
  expect_failures = [var.lookback_days]
}

run "rejects_fractional_lookback_days" {
  command = plan
  variables { lookback_days = 1.5 }
  expect_failures = [var.lookback_days]
}

run "rejects_six_credit_notification_users" {
  command = plan
  variables { credit_notification_users = ["A", "B", "C", "D", "E", "F"] }
  expect_failures = [var.credit_notification_users]
}

run "rejects_pem_public_key" {
  command = plan
  variables { query_user_public_key = "-----BEGIN PUBLIC KEY-----" }
  expect_failures = [var.query_user_public_key]
}
