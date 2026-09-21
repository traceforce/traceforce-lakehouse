# Child module: the caller's root configuration supplies the google provider (project and the
# location, which must be the logs bucket's location) and the state backend. See README.
terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0.0"
    }
  }
}
