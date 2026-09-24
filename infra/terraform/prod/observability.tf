# Basic observability, on purpose not more than that: CloudWatch only
# (no Sentry, no Grafana), staying inside the free tier's usual limits
# — well under 10 custom metrics, 10 alarms, 1 dashboard. Custom metrics
# in use: WellisStatus/{RemindersDue,RemindersSent,RemindersFailed,
# OverdueReminders,Uptime,LatencyMs,ErrorLogs} = 7. Alarms: 5. Dashboards: 1.

resource "aws_sns_topic" "alerts" {
  name = "wellis-status-alerts"
}

# SNS requires the subscriber to click a confirmation link in an email
# before anything actually delivers -- that happens outside Terraform,
# after apply.
resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------------------------------------------------------------------
# Error-log metric filters. Both portal (portal/src/app.js's error
# middleware) and notifier (notifier/notifier.py's log.warning calls)
# write JSON log lines with "level":"error" for exactly this reason: one
# filter pattern, one shared metric, matching on both log groups. This
# is the "no Sentry" substitute -- basic, not perfect: it counts error
# lines, it doesn't capture stack traces or dedupe by error type.
# ---------------------------------------------------------------------
resource "aws_cloudwatch_log_metric_filter" "portal_errors" {
  name           = "wellis-status-portal-errors"
  log_group_name = aws_cloudwatch_log_group.portal.name
  pattern        = "{ $.level = \"error\" }"

  metric_transformation {
    name      = "ErrorLogs"
    namespace = "WellisStatus"
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "notifier_errors" {
  name           = "wellis-status-notifier-errors"
  log_group_name = aws_cloudwatch_log_group.notifier.name
  pattern        = "{ $.level = \"error\" }"

  metric_transformation {
    name      = "ErrorLogs"
    namespace = "WellisStatus"
    value     = "1"
    unit      = "Count"
  }
}

# ---------------------------------------------------------------------
# Alarms. All go to the same SNS topic on both ALARM and OK, so a
# recovery is as visible as the original page.
# ---------------------------------------------------------------------

# VERIFIED against AWS's own docs (docs.aws.amazon.com/lambda/latest/dg/urls-monitoring.html),
# not guessed: Url5xxCount/Url4xxCount/UrlRequestCount/UrlRequestLatency
# are real AWS/Lambda metrics for function URLs specifically, dimensioned
# by FunctionName (aggregates $LATEST + all aliases), Resource
# (FunctionName:Qualifier, e.g. "name:$LATEST"), or ExecutedVersion. The
# portal's function URL has no alias/version qualifier configured, so
# FunctionName is the right (and simplest) dimension here.
resource "aws_cloudwatch_metric_alarm" "portal_5xx" {
  alarm_name          = "wellis-status-portal-5xx"
  namespace           = "AWS/Lambda"
  metric_name         = "Url5xxCount"
  dimensions          = { FunctionName = aws_lambda_function.portal.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  # No requests in the window means no 5xxs, not an unknown/bad state.
  treat_missing_data = "notBreaching"
  alarm_actions      = [aws_sns_topic.alerts.arn]
  ok_actions         = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "error_logs" {
  alarm_name          = "wellis-status-error-logs"
  namespace           = "WellisStatus"
  metric_name         = "ErrorLogs"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  depends_on = [aws_cloudwatch_log_metric_filter.portal_errors, aws_cloudwatch_log_metric_filter.notifier_errors]
}

resource "aws_cloudwatch_metric_alarm" "notifier_errors" {
  alarm_name          = "wellis-status-notifier-lambda-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.notifier.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# Missing data = breaching, deliberately: a notifier that has stopped
# running entirely (crashed, deploy broke it, EventBridge Scheduler
# disabled) also stops emitting OverdueReminders, and that has to alarm
# just as loudly as an actual backlog -- "no news" isn't "good news"
# for this one. 2 x 15 min matches the notifier's own schedule
# (rate(15 minutes) in lambda_notifier.tf), so this needs two misses in
# a row before paging, not one blip.
resource "aws_cloudwatch_metric_alarm" "overdue_reminders" {
  alarm_name          = "wellis-status-overdue-reminders"
  namespace           = "WellisStatus"
  metric_name         = "OverdueReminders"
  statistic           = "Maximum"
  period              = 900
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# Same "missing = breaching" reasoning: if the uptime check itself has
# stopped running, that's indistinguishable from the portal being down
# for the purposes people actually care about (nobody can tell you
# whether the portal works), so it alarms the same way. 2 x 5 min
# matches the uptime check's own schedule (rate(5 minutes) below).
resource "aws_cloudwatch_metric_alarm" "portal_down" {
  alarm_name          = "wellis-status-portal-down"
  namespace           = "WellisStatus"
  metric_name         = "Uptime"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------------
# Dashboard: one page, the four things you'd actually check first.
# ---------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "wellis-status"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Portal: requests / 4xx / 5xx"
          region = var.aws_region
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/Lambda", "UrlRequestCount", "FunctionName", aws_lambda_function.portal.function_name],
            ["AWS/Lambda", "Url4xxCount", "FunctionName", aws_lambda_function.portal.function_name],
            ["AWS/Lambda", "Url5xxCount", "FunctionName", aws_lambda_function.portal.function_name],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Portal: latency (ms)"
          region = var.aws_region
          stat   = "Average"
          period = 300
          metrics = [
            ["AWS/Lambda", "UrlRequestLatency", "FunctionName", aws_lambda_function.portal.function_name],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Notifier: sent / failed / overdue"
          region = var.aws_region
          stat   = "Sum"
          period = 300
          metrics = [
            ["WellisStatus", "RemindersSent"],
            ["WellisStatus", "RemindersFailed"],
            ["WellisStatus", "OverdueReminders", { stat = "Maximum" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Uptime"
          region = var.aws_region
          stat   = "Minimum"
          period = 300
          metrics = [
            ["WellisStatus", "Uptime"],
          ]
        }
      },
    ]
  })
}

# ---------------------------------------------------------------------
# One saved Logs Insights query, across both log groups: everything
# currently tagged level=error, newest first. This is the "go look at
# what actually happened" companion to the ErrorLogs alarm above.
# ---------------------------------------------------------------------
resource "aws_cloudwatch_query_definition" "errors" {
  name = "wellis-status/errors"

  log_group_names = [
    aws_cloudwatch_log_group.portal.name,
    aws_cloudwatch_log_group.notifier.name,
  ]

  query_string = <<-EOT
    fields @timestamp, @log, @message
    | filter level = "error"
    | sort @timestamp desc
    | limit 100
  EOT
}
