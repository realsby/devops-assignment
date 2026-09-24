# portal_app / notifier_app must NOT be neon_role — roles created via the
# Neon API join neon_superuser, which is far more than either app needs.
# These go through the postgresql provider instead, connected as
# wellis_owner (see providers.tf), so they're ordinary least-privilege
# login roles. Grants stay in migrations/004_app_role_grants.sql, not
# here — this only creates LOGIN + password, matching how
# db/init/01_roles.sql does it locally.

resource "random_password" "portal_app" {
  length  = 32
  special = false # keeps it URL-safe in DATABASE_URL without encoding
}

resource "random_password" "notifier_app" {
  length  = 32
  special = false
}

resource "postgresql_role" "portal_app" {
  name     = "portal_app"
  login    = true
  password = random_password.portal_app.result
}

resource "postgresql_role" "notifier_app" {
  name     = "notifier_app"
  login    = true
  password = random_password.notifier_app.result
}
