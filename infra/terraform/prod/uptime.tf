# Tiny uptime check for the portal. A zip function, not a container --
# it's a dozen lines of stdlib Python with no dependencies, doesn't need
# ECR/CI to deploy, and doesn't need to share anything with the app
# images. See uptime/handler.py for the check itself and the caveat
# about it running inside AWS.
data "archive_file" "uptime" {
  type        = "zip"
  source_file = "${path.module}/uptime/handler.py"
  output_path = "${path.module}/.build/uptime.zip"
}

resource "aws_cloudwatch_log_group" "uptime" {
  name              = "/aws/lambda/wellis-status-uptime"
  retention_in_days = 30
}

resource "aws_iam_role" "uptime" {
  name               = "wellis-status-uptime"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# Logs only -- this function makes one outbound HTTPS call and writes
# its own logs, nothing else.
data "aws_iam_policy_document" "uptime_permissions" {
  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.uptime.arn}:*"]
  }
}

resource "aws_iam_role_policy" "uptime" {
  name   = "wellis-status-uptime"
  role   = aws_iam_role.uptime.id
  policy = data.aws_iam_policy_document.uptime_permissions.json
}

resource "aws_lambda_function" "uptime" {
  function_name    = "wellis-status-uptime"
  role             = aws_iam_role.uptime.arn
  runtime          = "python3.13"
  handler          = "handler.handler"
  filename         = data.archive_file.uptime.output_path
  source_code_hash = data.archive_file.uptime.output_base64sha256
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      PORTAL_URL = aws_lambda_function_url.portal.function_url
    }
  }

  depends_on = [aws_cloudwatch_log_group.uptime, aws_iam_role_policy.uptime]
}

# Own role, same pattern as notifier_scheduler in lambda_notifier.tf:
# Scheduler assumes this role directly to invoke, so it only needs an
# identity-based policy scoped to this one function -- no resource-based
# aws_lambda_permission needed.
resource "aws_iam_role" "uptime_scheduler" {
  name               = "wellis-status-uptime-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

data "aws_iam_policy_document" "uptime_scheduler_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.uptime.arn]
  }
}

resource "aws_iam_role_policy" "uptime_scheduler" {
  name   = "wellis-status-uptime-scheduler"
  role   = aws_iam_role.uptime_scheduler.id
  policy = data.aws_iam_policy_document.uptime_scheduler_permissions.json
}

resource "aws_scheduler_schedule" "uptime" {
  name       = "wellis-status-uptime"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = "rate(5 minutes)"

  target {
    arn      = aws_lambda_function.uptime.arn
    role_arn = aws_iam_role.uptime_scheduler.arn

    retry_policy {
      maximum_retry_attempts = 0
    }
  }
}
