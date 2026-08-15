# Detection path: EventBridge -> bridge Lambda -> HMAC-signed webhook POST.
#
# The Lambda is a generic proxy: it forwards whatever EventBridge sends it and
# does not interpret any of it. Which signals reach the agent is therefore
# entirely a function of the rules below, so adding one - health check failures,
# crashes, latency, error rates - is a new entry in local.event_rules and no code
# change.
#
# The ECS task-stopped rule is the demo's trigger and is sufficient on its own.
# The memory alarm is an optional second trigger (enable_memory_alarm) that only
# buys an earlier start. It is off by default.

resource "aws_secretsmanager_secret" "webhook" {
  name                    = "${var.name_prefix}/webhook"
  description             = "DevOps Agent webhook URL and HMAC secret"
  recovery_window_in_days = 0
}

# Placeholder only. scripts/setup-webhook.sh fills this in after the space
# exists, so Terraform must not fight that update.
resource "aws_secretsmanager_secret_version" "webhook" {
  secret_id = aws_secretsmanager_secret.webhook.id
  secret_string = jsonencode({
    webhookUrl    = "REPLACE_ME"
    webhookSecret = "REPLACE_ME"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

data "archive_file" "bridge" {
  type        = "zip"
  source_file = "${path.module}/lambda/incident_bridge.py"
  output_path = "${path.module}/.build/incident_bridge.zip"
}

data "aws_iam_policy_document" "bridge_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "bridge" {
  statement {
    sid       = "ReadWebhookCredentials"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.webhook.arn]
  }
}

resource "aws_iam_role" "bridge" {
  name               = "${var.name_prefix}-incident-bridge"
  assume_role_policy = data.aws_iam_policy_document.bridge_assume.json
}

resource "aws_iam_role_policy" "bridge" {
  name   = "read-webhook-credentials"
  role   = aws_iam_role.bridge.id
  policy = data.aws_iam_policy_document.bridge.json
}

resource "aws_iam_role_policy_attachment" "bridge_logs" {
  role       = aws_iam_role.bridge.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "bridge" {
  name              = "/aws/lambda/${var.name_prefix}-incident-bridge"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "bridge" {
  function_name    = "${var.name_prefix}-incident-bridge"
  role             = aws_iam_role.bridge.arn
  handler          = "incident_bridge.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.bridge.output_path
  source_code_hash = data.archive_file.bridge.output_base64sha256

  environment {
    variables = {
      SECRET_ARN = aws_secretsmanager_secret.webhook.arn
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.bridge_logs,
    aws_cloudwatch_log_group.bridge,
  ]
}

# --- Optional early trigger: memory climbing ----------------------------------

resource "aws_cloudwatch_metric_alarm" "memory" {
  count = var.enable_memory_alarm ? 1 : 0

  alarm_name          = "${var.name_prefix}-order-processor-memory"
  alarm_description   = "Service memory utilization is climbing toward the container limit"
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = var.memory_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.this.name
    ServiceName = aws_ecs_service.order_processor.name
  }
}

resource "aws_cloudwatch_event_rule" "alarm" {
  count = var.enable_memory_alarm ? 1 : 0

  name        = "${var.name_prefix}-memory-alarm"
  description = "Forward the memory alarm to the DevOps Agent bridge"

  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [aws_cloudwatch_metric_alarm.memory[0].alarm_name]
      state = {
        value = ["ALARM"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "alarm" {
  count = var.enable_memory_alarm ? 1 : 0

  rule      = aws_cloudwatch_event_rule.alarm[0].name
  target_id = "incident-bridge"
  arn       = aws_lambda_function.bridge.arn
}

resource "aws_lambda_permission" "alarm" {
  count = var.enable_memory_alarm ? 1 : 0

  statement_id  = "AllowExecutionFromEventBridgeAlarm"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bridge.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.alarm[0].arn
}

# --- Signals -------------------------------------------------------------------

locals {
  # Every entry here becomes a rule pointing at the same Lambda. Override the
  # whole map with var.event_rules to feed the agent something else entirely.
  default_event_rules = {
    # Filtering on stopCode rather than the stoppedReason string keeps normal
    # rolling-deploy stops out: those arrive as ServiceSchedulerInitiated.
    task-stopped = jsonencode({
      source        = ["aws.ecs"]
      "detail-type" = ["ECS Task State Change"]
      detail = {
        clusterArn = [aws_ecs_cluster.this.arn]
        lastStatus = ["STOPPED"]
        stopCode   = ["EssentialContainerExited", "TaskFailedToStart"]
      }
    })
  }

  event_rules = length(var.event_rules) > 0 ? var.event_rules : local.default_event_rules
}

# The ECS rule predates the for_each map and keeps its name, so migrate it in
# state rather than letting Terraform recreate it into its own name. Safe to
# delete once applied; only affects stacks deployed before this change.
moved {
  from = aws_cloudwatch_event_rule.task_stopped
  to   = aws_cloudwatch_event_rule.signal["task-stopped"]
}

moved {
  from = aws_cloudwatch_event_target.task_stopped
  to   = aws_cloudwatch_event_target.signal["task-stopped"]
}

moved {
  from = aws_lambda_permission.task_stopped
  to   = aws_lambda_permission.signal["task-stopped"]
}

resource "aws_cloudwatch_event_rule" "signal" {
  for_each = local.event_rules

  name          = "${var.name_prefix}-${each.key}"
  description   = "Forward ${each.key} events to the DevOps Agent bridge"
  event_pattern = each.value
}

resource "aws_cloudwatch_event_target" "signal" {
  for_each = local.event_rules

  rule      = aws_cloudwatch_event_rule.signal[each.key].name
  target_id = "incident-bridge"
  arn       = aws_lambda_function.bridge.arn
}

resource "aws_lambda_permission" "signal" {
  for_each = local.event_rules

  statement_id  = "AllowExecutionFromEventBridge-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bridge.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.signal[each.key].arn
}
