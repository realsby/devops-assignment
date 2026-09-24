data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_log_group" "portal" {
  name              = "/aws/lambda/wellis-status-portal"
  retention_in_days = 30
}

resource "aws_iam_role" "portal" {
  name               = "wellis-status-portal"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# One role per function: only its own log group, only its own SSM path.
data "aws_iam_policy_document" "portal_permissions" {
  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.portal.arn}:*"]
  }

  statement {
    sid     = "ReadOwnParams"
    effect  = "Allow"
    actions = ["ssm:GetParametersByPath"]
    # GetParametersByPath is authorised against the path itself, so the
    # bare path is needed as well as the children.
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/wellis/prod/portal",
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/wellis/prod/portal/*",
    ]
  }
}

resource "aws_iam_role_policy" "portal" {
  name   = "wellis-status-portal"
  role   = aws_iam_role.portal.id
  policy = data.aws_iam_policy_document.portal_permissions.json
}

resource "aws_lambda_function" "portal" {
  function_name = "wellis-status-portal"
  role          = aws_iam_role.portal.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.portal.repository_url}:${var.image_tag}"
  architectures = ["x86_64"]
  memory_size   = 512
  timeout       = 10

  # Caps concurrent DB connections (paired with PG_POOL_MAX below) and
  # cost — this is an internal care-team tool, not public-scale traffic.
  reserved_concurrent_executions = 5

  environment {
    variables = {
      SSM_PARAMETER_PATH = "/wellis/prod/portal"
      PG_POOL_MAX        = "2"
    }
  }

  depends_on = [aws_cloudwatch_log_group.portal, aws_iam_role_policy.portal]

  # CI deploys via UpdateFunctionCode, not terraform apply — don't let a
  # later plan roll the running image back to whatever tag was last
  # applied here.
  lifecycle {
    ignore_changes = [image_uri]
  }
}

resource "aws_lambda_function_url" "portal" {
  function_name      = aws_lambda_function.portal.function_name
  authorization_type = "NONE" # the app does its own auth — see portal/src/auth.js
}

# Public function URLs need BOTH of these as of the Oct 2025 AWS change —
# VERIFIED against current AWS docs (docs.aws.amazon.com/lambda/latest/dg/urls-auth.html)
# and the aws_lambda_permission resource schema, not guessed. Still worth
# your own curl check post-apply, as you planned.
resource "aws_lambda_permission" "portal_url_invoke_url" {
  statement_id           = "FunctionURLAllowPublicAccess"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.portal.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "portal_url_invoke_function" {
  statement_id             = "FunctionURLInvokeAllowPublicAccess"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.portal.function_name
  principal                = "*"
  invoked_via_function_url = true
}
