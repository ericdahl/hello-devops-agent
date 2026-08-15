output "agent_space_id" {
  description = "Agent space id, for aws devops-agent CLI calls"
  value       = awscc_devopsagent_agent_space.this.agent_space_id
}

output "agent_space_arn" {
  description = "Use this to narrow the aws:SourceArn condition in agent.tf once the space exists"
  value       = awscc_devopsagent_agent_space.this.arn
}

# The operator web app is where investigations are actually read. It lives on its
# own domain, outside the AWS console.
output "operator_app_url" {
  value = "https://${awscc_devopsagent_agent_space.this.agent_space_id}.aidevops.global.app.aws"
}

output "console_url" {
  description = "Agent space in the AWS console, for configuration rather than investigations"
  value       = "https://${var.region}.console.aws.amazon.com/aidevops/home?region=${var.region}#/spaces/${awscc_devopsagent_agent_space.this.agent_space_id}"
}

output "list_investigations_command" {
  value = "aws devops-agent list-backlog-tasks --agent-space-id ${awscc_devopsagent_agent_space.this.agent_space_id} --region ${var.region}"
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_name" {
  value = aws_ecs_service.order_processor.name
}

output "service_log_group" {
  value = aws_cloudwatch_log_group.service.name
}

output "bridge_log_group" {
  description = "Check here first if no investigation appears"
  value       = aws_cloudwatch_log_group.bridge.name
}

output "app_version" {
  description = "Version currently deployed; changes when cache_key_mode flips"
  value       = local.app_version
}

output "region" {
  value = var.region
}

output "webhook_secret_id" {
  description = "Populated by scripts/setup-webhook.sh"
  value       = aws_secretsmanager_secret.webhook.id
}

output "watch_tasks_command" {
  description = "Watch tasks come and go during the crash loop"
  value       = "aws ecs list-tasks --cluster ${aws_ecs_cluster.this.name} --region ${var.region} --desired-status STOPPED"
}

output "tail_service_logs_command" {
  value = "aws logs tail ${aws_cloudwatch_log_group.service.name} --follow --region ${var.region}"
}

output "agent_space_log_group" {
  description = "Agent space delivery-path logs: which webhook fired, which association, what error"
  value       = aws_cloudwatch_log_group.agent_space.name
}
