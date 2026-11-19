# Same requirements as the module that lived here (now terraform/aws/athena), so terraform init
# succeeds with an existing lock file.
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.44.0"
    }
  }
}
