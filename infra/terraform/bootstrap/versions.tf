# Started with local state (this module creates the bucket everything
# else stores state in), then moved into that bucket after the first
# apply with `terraform init -migrate-state`.
terraform {
  required_version = ">= 1.9"

  backend "s3" {
    bucket       = "wellis-status-tfstate-151177426529"
    key          = "bootstrap/terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
