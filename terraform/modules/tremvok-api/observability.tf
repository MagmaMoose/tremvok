# Silence is the failure mode. A deployment-record service that has stopped working looks
# exactly like a quiet week — no records, no notifications, nothing red anywhere, because every
# caller is failure-isolated by design and will not complain on its own.
#
# So the alarm watches from OUTSIDE the function. While it is firing, an empty deployment
# history means the recorder is broken rather than that nobody deployed.
resource "aws_cloudwatch_metric_alarm" "errors" {
  # Skipped locally: LocalStack accepts alarms and never evaluates them, so creating one would
  # prove nothing while looking like coverage.
  count = var.localstack ? 0 : 1

  alarm_name          = "${var.name}-failing"
  alarm_description   = "The Tremvok API is erroring. Until this clears, an empty deployment history means the recorder is broken, not that nothing was deployed."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  # Errors is a sum, so an idle period reports nothing rather than zero. `notBreaching` stops a
  # quiet afternoon from reading as an alarm state.
  treat_missing_data = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.api.function_name
  }

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions

  tags = local.tags
}

# The throttle is the cost ceiling, and a throttle doing its job is indistinguishable from an
# outage to whoever is being throttled. This says which one is happening.
resource "aws_cloudwatch_metric_alarm" "throttled" {
  count = var.localstack ? 0 : 1

  alarm_name          = "${var.name}-throttled"
  alarm_description   = "Requests are being rejected at the throttle. Either something is looping, or real traffic has outgrown ${var.throttle_rate_limit} req/s and the limit needs raising deliberately."
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.api.function_name
  }

  alarm_actions = var.alarm_actions

  tags = local.tags
}
