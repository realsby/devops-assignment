# VERIFIED, not guessed: this exact resource block was checked against
# the real project with `terraform plan` after the import block below
# (using a throwaway config, NEON_API_KEY only, no AWS credentials
# needed). Result: "Plan: 1 to import, 0 to add, 0 to change, 0 to
# destroy." — clean, so the import block stays; nothing here needed to
# be dropped in favor of a data-source reference.
import {
  to = neon_project.wellis
  id = var.neon_project_id
}

resource "neon_project" "wellis" {
  name                      = "code-challenge"
  org_id                    = var.neon_org_id
  region_id                 = "aws-eu-central-1"
  pg_version                = 18
  compute_provisioner       = "k8s-neonvm"
  default_branch_protected  = false
  history_retention_seconds = 21600
  store_password            = "yes"
  suspend_timeout_seconds   = 0
  autoscaling_limit_min_cu  = 0.25
  autoscaling_limit_max_cu  = 2

  # The project's existing default branch/database/role — this is Neon's
  # demo data, untouched. wellis_owner/wellis (below) are new siblings on
  # this same branch, not a replacement for these.
  branch {
    name          = "production"
    database_name = "demo"
    role_name     = "demo_owner"
  }

  maintenance_window {
    weekdays   = [2]
    start_time = "03:00"
    end_time   = "04:00"
  }

  primary_compute {
    autoscaling_limit_min_cu = 0.25
    autoscaling_limit_max_cu = 2
    suspend_timeout_seconds  = 0
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "neon_role" "wellis_owner" {
  project_id = neon_project.wellis.id
  branch_id  = neon_project.wellis.default_branch_id
  name       = "wellis_owner"
}

resource "neon_database" "wellis" {
  project_id = neon_project.wellis.id
  branch_id  = neon_project.wellis.default_branch_id
  name       = "wellis"
  owner_name = neon_role.wellis_owner.name
}
