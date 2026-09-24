# Looked up, not re-created — the OIDC provider itself lives in
# infra/terraform/bootstrap (one per account; this role needs prod-only
# resource ARNs it can't have until prod's own resources exist, so the
# role can't live in bootstrap too).
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_deploy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only main, only this repo — a PR from a fork (or any other branch)
    # gets no token at all, not a scoped-down one.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name               = "wellis-status-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_deploy_trust.json
}

data "aws_iam_policy_document" "github_deploy_permissions" {
  # ecr:GetAuthorizationToken has no resource-level permissions — this
  # is the standard, unavoidable "*" for it, not a scope leak.
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      # scripts/deploy.sh checks this before pushing: tags are immutable
      # (see ecr.tf), so re-running a deploy for a commit already pushed
      # once (e.g. retrying after a failed smoke test) must skip the
      # push instead of failing on an immutable-tag conflict.
      "ecr:DescribeImages",
    ]
    resources = [
      aws_ecr_repository.portal.arn,
      aws_ecr_repository.notifier.arn,
    ]
  }

  statement {
    sid    = "DeployFunctions"
    effect = "Allow"
    actions = [
      "lambda:UpdateFunctionCode",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
    ]
    resources = [
      aws_lambda_function.portal.arn,
      aws_lambda_function.notifier.arn,
    ]
  }

  # Exactly the two params CI needs and nothing else: the migrator URL to
  # run scripts/migrate.sh, and the ci-smoke token to hit the deployed
  # portal after deploying. Not the app DATABASE_URLs, not the reviewer
  # token.
  statement {
    sid     = "MigratorAndSmokeToken"
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      aws_ssm_parameter.migrator_database_url.arn,
      aws_ssm_parameter.token_ci_smoke.arn,
    ]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "wellis-status-github-deploy"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy_permissions.json
}
