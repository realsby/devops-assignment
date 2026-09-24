terraform {
  required_version = ">= 1.9"

  # Bucket name is hardcoded (backend blocks can't reference resources or
  # variables) and must match infra/terraform/bootstrap/s3_state.tf's
  # output exactly: wellis-status-tfstate-<account_id>, account
  # 151177426529 (backendlab-production, from ~/.aws/config).
  #
  # use_lockfile uses S3's own conditional-write locking — no DynamoDB
  # table needed.
  backend "s3" {
    bucket       = "wellis-status-tfstate-151177426529"
    key          = "prod/terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    neon = {
      source  = "kislerdm/neon"
      version = "~> 0.18"
    }
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "~> 1.27"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}
