# Named tokens (per portal/src/auth.js: API_TOKENS is comma-separated
# name:sha256hex). Raw values go to SSM individually so a specific
# person/consumer's token can be rotated or looked up without touching
# the others; only the hashes go into portal's own API_TOKENS param.
resource "random_password" "token_reviewer" {
  length  = 40
  special = false
}

resource "random_password" "token_ci_smoke" {
  length  = 40
  special = false
}

locals {
  api_tokens = join(",", [
    "reviewer:${sha256(random_password.token_reviewer.result)}",
    "ci-smoke:${sha256(random_password.token_ci_smoke.result)}",
  ])

  # Pooler host + sslmode=require for the apps (short-lived Lambda
  # connections, fine with pgbouncer-style pooling). Direct host for the
  # migrator: migrate.sh needs its lock_timeout/statement_timeout
  # (PGOPTIONS), which the pooler doesn't pass through.
  portal_database_url   = "postgresql://portal_app:${urlencode(random_password.portal_app.result)}@${neon_project.wellis.database_host_pooler}/${neon_database.wellis.name}?sslmode=require"
  notifier_database_url = "postgresql://notifier_app:${urlencode(random_password.notifier_app.result)}@${neon_project.wellis.database_host_pooler}/${neon_database.wellis.name}?sslmode=require"
  migrator_database_url = "postgresql://wellis_owner:${urlencode(neon_role.wellis_owner.password)}@${neon_project.wellis.database_host}/${neon_database.wellis.name}?sslmode=require"
}

resource "aws_ssm_parameter" "portal_database_url" {
  name  = "/wellis/prod/portal/DATABASE_URL"
  type  = "SecureString"
  value = local.portal_database_url
}

resource "aws_ssm_parameter" "portal_api_tokens" {
  name  = "/wellis/prod/portal/API_TOKENS"
  type  = "SecureString"
  value = local.api_tokens
}

resource "aws_ssm_parameter" "notifier_database_url" {
  name  = "/wellis/prod/notifier/DATABASE_URL"
  type  = "SecureString"
  value = local.notifier_database_url
}

# Owner URL, direct host. Not read by either app — only by whoever/
# whatever runs scripts/migrate.sh against prod (CI's migrate job, a
# later task, or by hand).
resource "aws_ssm_parameter" "migrator_database_url" {
  name  = "/wellis/prod/migrator/DATABASE_URL"
  type  = "SecureString"
  value = local.migrator_database_url
}

resource "aws_ssm_parameter" "token_reviewer" {
  name  = "/wellis/prod/tokens/reviewer"
  type  = "SecureString"
  value = random_password.token_reviewer.result
}

resource "aws_ssm_parameter" "token_ci_smoke" {
  name  = "/wellis/prod/tokens/ci-smoke"
  type  = "SecureString"
  value = random_password.token_ci_smoke.result
}
