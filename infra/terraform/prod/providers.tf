# Run with:
#   AWS_PROFILE=backendlab-production \
#   NEON_API_KEY="$(cat ~/.config/wellis/neon_api_key)" \
#   terraform plan
#
# NEON_API_KEY is read by the neon provider from the environment —
# nothing below references it, and it must never end up in a .tf file,
# tfvars, or the state's plaintext (the provider keeps it out of state).

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      project    = "wellis-status"
      env        = "prod"
      managed_by = "terraform"
    }
  }
}

provider "neon" {}

# Connects as wellis_owner (a neon_superuser-class role — see neon.tf) to
# manage the two app roles. GUESSED: superuser = false is the documented
# way to tell this provider "the connected role isn't a true Postgres
# superuser" for managed platforms like Neon/RDS, so it skips operations
# that would fail — I've used this pattern before but haven't verified
# it specifically against Neon with this provider version.
#
# Depends on neon_database.wellis existing (via the `database` argument
# referencing it), so this provider can't configure successfully until
# that resource exists — part of why the first-ever apply needs staging,
# same shape as the ECR/Lambda image chicken-and-egg. See variables.tf.
provider "postgresql" {
  host            = neon_project.wellis.database_host
  port            = 5432
  database        = neon_database.wellis.name
  username        = "wellis_owner"
  password        = neon_role.wellis_owner.password
  sslmode         = "require"
  superuser       = false
  connect_timeout = 15
}

data "aws_caller_identity" "current" {}
