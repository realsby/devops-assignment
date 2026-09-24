output "state_bucket" {
  value       = aws_s3_bucket.state.id
  description = "Must match the hardcoded bucket name in infra/terraform/prod/versions.tf."
}

output "github_oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}
