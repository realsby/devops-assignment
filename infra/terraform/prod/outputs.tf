output "portal_function_url" {
  value = aws_lambda_function_url.portal.function_url
}

output "ecr_portal_repository_url" {
  value = aws_ecr_repository.portal.repository_url
}

output "ecr_notifier_repository_url" {
  value = aws_ecr_repository.notifier.repository_url
}

output "github_deploy_role_arn" {
  value = aws_iam_role.github_deploy.arn
}
