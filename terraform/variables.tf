variable "region" {
  description = "Region for the agent space and the demo workload. Must be a DevOps Agent supported region."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix applied to every resource name."
  type        = string
  default     = "hello-devops-agent"
}

variable "enable_leak" {
  description = <<-EOT
    Phase switch for the demo. false deploys the healthy build; flipping it to
    true registers a new task definition revision that retains memory, which is
    the change the agent is expected to find.
  EOT
  type        = bool
  default     = false
}

variable "leak_mb_per_min" {
  description = "Memory retained per minute when enable_leak is true. 120 reaches the container limit in roughly three minutes."
  type        = number
  default     = 120
}

variable "task_memory" {
  description = "Fargate task memory (MiB)."
  type        = number
  default     = 512
}

variable "task_cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 256
}

variable "container_memory_hard" {
  description = <<-EOT
    Container hard memory limit (MiB). Kept below task_memory so the container is
    OOM-killed first, which produces stopCode EssentialContainerExited and an
    "OutOfMemoryError" stoppedReason rather than a platform-level task failure.
  EOT
  type        = number
  default     = 400
}

variable "desired_count" {
  description = "Tasks to run. Set to 0 to halt a crash loop without tearing anything down - investigations already opened stay readable."
  type        = number
  default     = 1
}

variable "enable_memory_alarm" {
  description = <<-EOT
    Off by default, and the demo works without it.

    The agent is not watching your metrics - something has to POST to the webhook
    before it does anything. But once triggered it queries CloudWatch, CloudTrail,
    logs and task definitions itself using its read-only role, so it does not need
    an alarm to discover memory pressure. The ECS task-stopped event alone carries
    exit code 137 and "OutOfMemoryError", which is everything the agent needs to
    start.

    Turn this on only if you want an investigation to open while memory is still
    climbing, rather than ~90 seconds later when the container is killed.
  EOT
  type        = bool
  default     = false
}

variable "memory_alarm_threshold" {
  description = <<-EOT
    Threshold for the AWS/ECS MemoryUtilization alarm, as a percentage.

    Watch the denominator: MemoryUtilization is measured against task_memory,
    but the container is killed at container_memory_hard. With the defaults the
    container dies at 400/512 = 78% of task memory, and 60-second sampling means
    the last datapoint before the kill is lower still - an observed run peaked at
    69%. A threshold of 80 is therefore unreachable and the alarm never fires.
    Keep this comfortably below 100 * container_memory_hard / task_memory.
  EOT
  type        = number
  default     = 60
}

variable "enable_container_insights" {
  description = "Enables per-task memory metrics. Costs a few dollars a month at this scale but makes the investigation noticeably richer."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention for the service log group."
  type        = number
  default     = 7
}
