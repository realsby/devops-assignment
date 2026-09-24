# Run with: AWS_PROFILE=backendlab-production terraform plan
provider "aws" {
  region = "eu-central-1"

  default_tags {
    tags = {
      project    = "wellis-status"
      env        = "prod"
      managed_by = "terraform"
      component  = "bootstrap"
    }
  }
}

data "aws_caller_identity" "current" {}
