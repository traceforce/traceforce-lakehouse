# The AWS (Athena) module moved to terraform/aws/athena. This stub makes a configuration that
# bumps ?ref= but keeps the old source path fail with the fix, not a bare "Unsupported argument".
# It accepts the old inputs (variables.tf) and outputs (outputs.tf), so the move message is the
# only error. The logs_bucket validation raises it first, before Terraform computes any changes,
# so existing resources are never listed as "will be destroyed" and nothing can be applied; the
# precondition below repeats it.
#
# The move needs no state changes: resource addresses are module.<block name>.<resource>, without
# the source path.
#
# Remove this stub a few releases after the move; the release notes name the release.
resource "terraform_data" "moved" {
  lifecycle {
    precondition {
      # Always false. Terraform rejects a bare `false` ("must refer to at least one object"), so it
      # refers to the input, inside a list so the condition stays known when the input isn't.
      condition     = length([var.logs_bucket]) < 0
      error_message = "The TraceForce AWS (Athena) module moved to //terraform/aws/athena. In your module block, change source to github.com/traceforce/traceforce-lakehouse//terraform/aws/athena (keep the same ?ref=) and run terraform init -upgrade. The move itself changes no resources."
    }
  }
}
