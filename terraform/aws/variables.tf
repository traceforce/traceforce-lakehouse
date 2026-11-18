# The old module's inputs, accepted and ignored, so a configuration still passing them gets the
# move message rather than "Unsupported argument". Same names, types and defaults as
# terraform/aws/athena/variables.tf.

variable "logs_bucket" {
  description = "Ignored: this module moved to //terraform/aws/athena."
  type        = string
  # Always fails, during validation, before Terraform computes any changes: existing resources
  # are never listed as "will be destroyed". The one-element list keeps the condition known (false)
  # even when the bucket name is only known after apply.
  validation {
    condition     = length([var.logs_bucket]) < 0
    error_message = "The TraceForce AWS (Athena) module moved to //terraform/aws/athena. In your module block, change source to github.com/traceforce/traceforce-lakehouse//terraform/aws/athena (keep the same ?ref=) and run terraform init -upgrade. The move itself changes no resources."
  }
}

variable "logs_prefix" {
  description = "Ignored: this module moved to //terraform/aws/athena."
  type        = string
  default     = ""
}

variable "logs_kms_key_arn" {
  description = "Ignored: this module moved to //terraform/aws/athena."
  type        = string
  default     = null
}

variable "alarm_sns_topic_arn" {
  description = "Ignored: this module moved to //terraform/aws/athena."
  type        = string
  default     = null
}

variable "create_glue_integration" {
  description = "Ignored: this module moved to //terraform/aws/athena."
  type        = bool
  default     = true
}

variable "query_trusted_principals" {
  description = "Ignored: this module moved to //terraform/aws/athena."
  type        = list(string)
  default     = []
}
