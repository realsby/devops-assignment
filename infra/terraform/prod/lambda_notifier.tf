resource "aws_cloudwatch_log_group" "notifier" {
  name              = "/aws/lambda/wellis-status-notifier"
  retention_in_days = 30
}

resource "aws_iam_role" "notifier" {
  name               = "wellis-status-notifier"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "notifier_permissions" {
  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.notifier.arn}:*"]
  }

  statement {
    sid     = "ReadOwnParams"
    effect  = "Allow"
    actions = ["ssm:GetParametersByPath"]
    # GetParametersByPath is authorised against the path itself, so the
    # bare path is needed as well as the children.
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/wellis/prod/notifier",
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/wellis/prod/notifier/*",
    ]
  }

  statement {
    sid       = "PutReceipts"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.receipts.arn}/receipts/*"]
  }
}

resource "aws_iam_role_policy" "notifier" {
  name   = "wellis-status-notifier"
  role   = aws_iam_role.notifier.id
  policy = data.aws_iam_policy_document.notifier_permissions.json
}

resource "aws_lambda_function" "notifier" {
  function_name = "wellis-status-notifier"
  role          = aws_iam_role.notifier.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.notifier.repository_url}:${var.image_tag}"
  architectures = ["x86_64"]
  memory_size   = 256
  timeout       = 60

  # No overlapping runs — two concurrent invocations could both pick up
  # the same due reminder and double-send it.
  reserved_concurrent_executions = 1

  environment {
    variables = {
      SSM_PARAMETER_PATH = "/wellis/prod/notifier"
      RECEIPT_BUCKET     = aws_s3_bucket.receipts.bucket
    }
  }

  depends_on = [aws_cloudwatch_log_group.notifier, aws_iam_role_policy.notifier]

  lifecycle {
    ignore_changes = [image_uri]
  }
}

# EventBridge Scheduler, not a classic EventBridge rule: it invokes the
# target by assuming target.role_arn directly, so (unlike a classic rule
# invoking as the events.amazonaws.com service principal) no separate
# resource-based aws_lambda_permission is needed here — the role's own
# identity-based policy below is what actually grants the invoke.
data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "notifier_scheduler" {
  name               = "wellis-status-notifier-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

data "aws_iam_policy_document" "notifier_scheduler_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.notifier.arn]
  }
}

resource "aws_iam_role_policy" "notifier_scheduler" {
  name   = "wellis-status-notifier-scheduler"
  role   = aws_iam_role.notifier_scheduler.id
  policy = data.aws_iam_policy_document.notifier_scheduler_permissions.json
}

# 15 minutes: reminders are always hours out (see notifier/notifier.py —
# fetch_due only pulls send_at <= now()), so nothing needs a tighter
# cadence, and it gives Neon room to actually scale to zero between runs
# on the free compute hours rather than being kept warm by us.
resource "aws_scheduler_schedule" "notifier" {
  name       = "wellis-status-notifier"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = "rate(15 minutes)"

  target {
    arn      = aws_lambda_function.notifier.arn
    role_arn = aws_iam_role.notifier_scheduler.arn

    retry_policy {
      maximum_retry_attempts = 0
    }
  }
}
