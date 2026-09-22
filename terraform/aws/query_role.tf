# Optional cross-account query role. When the team that runs Claude Code has no access to
# this account (e.g. a separate team owns the logs bucket), set query_trusted_principals to
# their AWS principal(s); they assume this role from their own identity to query. It carries
# exactly local.query_policy (read-only: Athena on this workgroup, the Iceberg tables, and
# its own results — nothing else). Not created when the list is empty.

resource "aws_iam_role" "query" {
  count = length(var.query_trusted_principals) > 0 ? 1 : 0
  name  = "${local.name}-query"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.query_trusted_principals }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "query" {
  count  = length(var.query_trusted_principals) > 0 ? 1 : 0
  name   = "query"
  role   = aws_iam_role.query[0].id
  policy = jsonencode(local.query_policy) # same document as the query_policy_json output
}
