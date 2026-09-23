# Child module: the caller's root configuration supplies the google provider (project only --
# the module derives the BigQuery location from the logs bucket) and the state backend. See README.
terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
}
