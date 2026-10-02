# Read-only Snowflake role for engineers/Claude Code to query the lakehouse. This is
# Snowflake-side RBAC for humans, distinct from the Azure RBAC in role_assignments.tf. Nobody
# holds it until reader_users lists usernames, query_user_public_key creates the module's query
# user (below), or someone runs GRANT ROLE "traceforce_lakehouse_reader" TO USER <name> --
# quoted, since the role is a lowercase identifier.
# To test what this role alone permits, run USE SECONDARY ROLES NONE first: sessions default to
# SECONDARY ROLES ALL, so a user who also holds a broader role can still write while using this one.
resource "snowflake_account_role" "reader" {
  name    = "traceforce_lakehouse_reader"
  comment = "Read-only access to the TraceForce lakehouse -- USAGE + SELECT + MONITOR only, no write privileges anywhere."
}

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

# ICEBERG TABLES, not TABLES: Snowflake's GRANT treats ICEBERG TABLE as its own object type,
# and every table this module creates is one. ALL covers existing tables, FUTURE covers ones
# added later; FUTURE is created first so a table created between the two grants is still
# covered.
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

# MONITOR is what makes INFORMATION_SCHEMA.TASK_HISTORY return rows (without it: zero rows, no
# error). It also allows SHOW/DESCRIBE TASK, never EXECUTE. FUTURE first, as with the tables.
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

# user_name is written as a quoted identifier, so reader_users must hold each user's exact
# stored name (uppercase unless the user was created with a quoted name).
resource "snowflake_grant_account_role" "reader" {
  for_each  = toset(var.reader_users)
  role_name = snowflake_account_role.reader.fully_qualified_name
  user_name = each.value
}

# Optional module-created query user: a SERVICE user (key-pair only) that holds nothing but the
# reader role, with secondary roles off, so the identity is read-only on its own whatever client
# connects -- the Azure counterpart of AWS's query role. The script's own checks still apply.
resource "snowflake_service_user" "query" {
  count = var.query_user_public_key == null ? 0 : 1

  name              = "traceforce_lakehouse_query"
  comment           = "TraceForce lakehouse read-only query user (key-pair auth, reader role only)."
  rsa_public_key    = var.query_user_public_key
  default_role      = snowflake_account_role.reader.name
  default_warehouse = snowflake_warehouse.lakehouse.name

  default_secondary_roles_option = "NONE"
  statement_timeout_in_seconds   = 300
  timezone                       = "UTC"
}

resource "snowflake_grant_account_role" "query_user" {
  count     = var.query_user_public_key == null ? 0 : 1
  role_name = snowflake_account_role.reader.fully_qualified_name
  user_name = snowflake_service_user.query[0].name
}
