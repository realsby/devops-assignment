# Local state on purpose: this module creates the S3 bucket that every
# other Terraform state (including its own, eventually) lives in. There's
# nothing to point a backend at yet.
#
# After the first apply: add a backend "s3" block here pointing at the
# bucket this module just created (key = "bootstrap/terraform.tfstate",
# same bucket as prod/), then `terraform init -migrate-state` once, by
# hand. Not done in this change — nothing to migrate into yet.
terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
