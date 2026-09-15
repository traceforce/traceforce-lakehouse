# Child module: the caller's root configuration supplies the aws provider (and therefore the
# region, which must be the logs bucket's region) and the state backend. See README.
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.44.0"
    }
  }
}
