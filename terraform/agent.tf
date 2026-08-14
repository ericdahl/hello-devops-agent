locals {
  # The role has to exist before the agent space, so the trust policy cannot
  # reference a concrete space ARN. This matches AWS's own CloudFormation
  # sample. To tighten it, apply once and then narrow to the exact ARN from
  # the agent_space_arn output.
  agent_space_arn_pattern = "arn:aws:aidevops:${var.region}:${data.aws_caller_identity.current.account_id}:agentspace/*"
}

data "aws_iam_policy_document" "agent_space_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["aidevops.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.agent_space_arn_pattern]
    }
  }
}

data "aws_iam_policy_document" "operator_app_assume" {
  statement {
    effect = "Allow"
    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]

    principals {
      type        = "Service"
      identifiers = ["aidevops.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.agent_space_arn_pattern]
    }
  }
}

# The agent creates this service-linked role on its first topology crawl.
data "aws_iam_policy_document" "resource_explorer_slr" {
  statement {
    sid       = "AllowCreateServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/resource-explorer-2.amazonaws.com/AWSServiceRoleForResourceExplorer"]
  }
}

resource "aws_iam_role" "agent_space" {
  name               = "${var.name_prefix}-agent-space"
  description        = "Assumed by DevOps Agent to read resources during investigations"
  assume_role_policy = data.aws_iam_policy_document.agent_space_assume.json
}

resource "aws_iam_role_policy_attachment" "agent_space_access" {
  role       = aws_iam_role.agent_space.name
  policy_arn = "arn:aws:iam::aws:policy/AIDevOpsAgentAccessPolicy"
}

resource "aws_iam_role_policy" "agent_space_slr" {
  name   = "allow-create-service-linked-roles"
  role   = aws_iam_role.agent_space.id
  policy = data.aws_iam_policy_document.resource_explorer_slr.json
}

resource "aws_iam_role" "operator_app" {
  name               = "${var.name_prefix}-operator-app"
  description        = "Backs human access to the DevOps Agent web app"
  assume_role_policy = data.aws_iam_policy_document.operator_app_assume.json
}

resource "aws_iam_role_policy_attachment" "operator_app_access" {
  role       = aws_iam_role.operator_app.name
  policy_arn = "arn:aws:iam::aws:policy/AIDevOpsOperatorAppAccessPolicy"
}

resource "awscc_devopsagent_agent_space" "this" {
  name        = var.name_prefix
  description = "ECS Fargate OOM investigation demo"

  operator_app = {
    iam = {
      operator_app_role_arn = aws_iam_role.operator_app.arn
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.agent_space_access,
    aws_iam_role_policy_attachment.operator_app_access,
    aws_iam_role_policy.agent_space_slr,
  ]
}

# account_type "monitor" is the primary account. A second account would be added
# as a separate association with source_aws / account_type "source".
resource "awscc_devopsagent_association" "this_account" {
  agent_space_id = awscc_devopsagent_agent_space.this.agent_space_id
  service_id     = "aws"

  configuration = {
    aws = {
      account_id         = data.aws_caller_identity.current.account_id
      account_type       = "monitor"
      assumable_role_arn = aws_iam_role.agent_space.arn
    }
  }
}
