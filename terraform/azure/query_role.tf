# Read-only Snowflake role for engineers/Claude Code to query the lakehouse tables directly --
# not wired to any Azure identity, unlike role_assignments.tf's roles (those are Azure RBAC,
# granted to Snowflake's own service principal so IT can read/write storage; this is
# Snowflake-side RBAC, for a human to query with). var.reader_users (AWS's
# query_trusted_principals / GCP's query_members) is empty by default, so the role and its
# grants exist either way, but nobody holds it until either that variable lists Snowflake
# usernames or a human runs GRANT ROLE "traceforce_lakehouse_reader" TO USER <you> by hand --
# quoted, since Terraform creates this role as a case-preserved lowercase identifier (the
# unquoted form folds to TRACEFORCE_LAKEHOUSE_READER and fails to resolve).
resource "snowflake_account_role" "reader" {
  name    = "traceforce_lakehouse_reader"
  comment = "Read-only access to the TraceForce lakehouse -- USAGE + SELECT + MONITOR only, no write privileges anywhere."
}

# A note for testing this role's read-only-ness: Snowflake sessions default to SECONDARY ROLES
# ALL, so a user who also independently holds a broader role (e.g. ACCOUNTADMIN) could still
# write even while USE ROLE'd to this one. A real test of what this role alone permits needs
# USE SECONDARY ROLES NONE first, or an actual low-privileged user who doesn't separately hold
# a broader role.

resource "snowflake_grant_privileges_to_account_role" "reader_warehouse" {
  account_role_name = snowflake_account_role.reader.name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.lakehouse.fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "reader_database" {
  account_role_name = snowflake_account_role.reader.name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.lakehouse.fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "reader_schema" {
  account_role_name = snowflake_account_role.reader.name
  privileges        = ["USAGE"]
  on_schema {
    schema_name = snowflake_schema.lakehouse.fully_qualified_name
  }
}

# ICEBERG TABLES, not TABLES -- every table this module creates (agent_events + the 18 export
# mirrors, tables.tf) is a snowflake_iceberg_table, and Snowflake's own GRANT syntax treats
# ICEBERG TABLE as its own object type distinct from a plain TABLE.
#
# Both ALL and FUTURE, not just ALL: ALL only covers tables that exist at apply time, so a
# reader granted before a new export table is added would need this file re-applied to see it.
# FUTURE covers that automatically -- both scoped to SELECT only, so neither can grant anything
# beyond read access no matter what's added later.
#
# reader_tables (ALL) depends_on reader_future_tables (FUTURE), not the other way around: with
# no explicit order, the one unsafe interleaving is ALL created, then a table created, then
# FUTURE created -- that table predates both grants' own object lists, so it's covered by
# neither. Forcing FUTURE to exist first closes this regardless of where the table's creation
# falls.
resource "snowflake_grant_privileges_to_account_role" "reader_future_tables" {
  account_role_name = snowflake_account_role.reader.name
  privileges        = ["SELECT"]
  on_schema_object {
    future {
      object_type_plural = "ICEBERG TABLES"
      in_schema          = snowflake_schema.lakehouse.fully_qualified_name
    }
  }
}

resource "snowflake_grant_privileges_to_account_role" "reader_tables" {
  account_role_name = snowflake_account_role.reader.name
  privileges        = ["SELECT"]
  on_schema_object {
    all {
      object_type_plural = "ICEBERG TABLES"
      in_schema          = snowflake_schema.lakehouse.fully_qualified_name
    }
  }
  depends_on = [snowflake_grant_privileges_to_account_role.reader_future_tables]
}

# MONITOR, not SELECT -- Tasks aren't queried directly, but MONITOR is what controls whether a
# role can see a Task's own run history. Without it, INFORMATION_SCHEMA.TASK_HISTORY silently
# returns zero rows instead of an error, easy to mistake for "no runs yet". This is the reader's
# real path to per-run error messages for a failed ingest/export Task, richer than the
# timestamp-only signal INFORMATION_SCHEMA.TABLES.LAST_ALTERED gives (see SKILL.md). MONITOR
# also grants SHOW TASKS/DESCRIBE TASK (a Task's full SQL body, not just state/timing/error
# text), but still no write capability -- it doesn't grant EXECUTE TASK or any ability to
# change what a Task does.
#
# reader_tasks (ALL) depends_on reader_future_tasks (FUTURE): same creation-gap reasoning as
# reader_future_tables/reader_tables above, applied to Tasks instead of tables.
resource "snowflake_grant_privileges_to_account_role" "reader_future_tasks" {
  account_role_name = snowflake_account_role.reader.name
  privileges        = ["MONITOR"]
  on_schema_object {
    future {
      object_type_plural = "TASKS"
      in_schema          = snowflake_schema.lakehouse.fully_qualified_name
    }
  }
}

resource "snowflake_grant_privileges_to_account_role" "reader_tasks" {
  account_role_name = snowflake_account_role.reader.name
  privileges        = ["MONITOR"]
  on_schema_object {
    all {
      object_type_plural = "TASKS"
      in_schema          = snowflake_schema.lakehouse.fully_qualified_name
    }
  }
  depends_on = [snowflake_grant_privileges_to_account_role.reader_future_tasks]
}

# Unquoted user_name, deliberately -- these are pre-existing Snowflake users this module
# doesn't create, so var.reader_users is expected to hold plain names the way a customer would
# type them into `GRANT ROLE x TO USER <name>` themselves in Snowsight (typically unquoted,
# case-folded to uppercase), not the quoted-lowercase convention this module's own Terraform-
# created objects use.
resource "snowflake_grant_account_role" "reader" {
  for_each  = toset(var.reader_users)
  role_name = snowflake_account_role.reader.fully_qualified_name
  user_name = each.value
}
