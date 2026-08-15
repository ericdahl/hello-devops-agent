# Vended log delivery for the agent space itself.
#
# This is the only view into the delivery path - which webhook fired, which
# association handled it, and what error came back. Without it, anything that
# goes wrong after the bridge Lambda gets its 200 is invisible: a misconfigured
# association, a dropped event, a backlog task that never appears.
#
# Not documented in the DevOps Agent user guide. The supported sources, formats
# and fields come from `aws logs describe-configuration-templates --service
# aidevops`, which reports resourceType agentspace and service, destinations
# CWL/S3/FH, and a field list covering webhook_id, association_id, status,
# error_type and error_message.
#
# Note what is NOT here: findings, hypotheses, or anything about how the agent
# reasons. That lives in journal records, via list-journal-records.

resource "aws_cloudwatch_log_group" "agent_space" {
  name              = "/aws/vendedlogs/aidevops/${var.name_prefix}"
  retention_in_days = var.log_retention_days
}

# Vended delivery writes as delivery.logs.amazonaws.com rather than as the agent
# space, so the destination log group has to admit that principal explicitly.
# The console does this silently; Terraform does not, and without it delivery
# succeeds at the API and then produces no logs.
data "aws_iam_policy_document" "vended_logs" {
  statement {
    sid    = "AllowVendedLogDelivery"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.agent_space.arn}:log-stream:*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "vended_logs" {
  policy_name     = "${var.name_prefix}-vended-logs"
  policy_document = data.aws_iam_policy_document.vended_logs.json
}

resource "aws_cloudwatch_log_delivery_source" "agent_space" {
  name         = "${var.name_prefix}-agent-space"
  log_type     = "APPLICATION_LOGS"
  resource_arn = awscc_devopsagent_agent_space.this.arn
}

resource "aws_cloudwatch_log_delivery_destination" "agent_space" {
  name          = "${var.name_prefix}-agent-space"
  output_format = "json"

  delivery_destination_configuration {
    destination_resource_arn = aws_cloudwatch_log_group.agent_space.arn
  }
}

resource "aws_cloudwatch_log_delivery" "agent_space" {
  delivery_source_name     = aws_cloudwatch_log_delivery_source.agent_space.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.agent_space.arn

  depends_on = [aws_cloudwatch_log_resource_policy.vended_logs]
}
