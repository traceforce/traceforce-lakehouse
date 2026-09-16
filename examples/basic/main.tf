# Minimal root configuration; mirrors the README. Replace the backend and values.
terraform {
  required_version = ">= 1.10" # native S3 state locking (use_lockfile)
  backend "s3" {
    bucket       = "acme-terraform-state" # NOT the logs bucket
    key          = "traceforce-lakehouse/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1" # must be the logs bucket's region
}

module "traceforce_lakehouse" {
  source      = "../../terraform" # customers: github.com/traceforce/traceforce-lakehouse//terraform?ref=1.0.0
  logs_bucket = "acme-traceforce-logs"
  logs_prefix = "traceforce"
}

output "query_policy_json" {
  value = module.traceforce_lakehouse.query_policy_json
}
