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

variable "cache_key_mode" {
  description = <<-EOT
    What the pricing cache is keyed on, and the phase switch for the demo.

    "sku"   - keyed on the product SKU. Bounded by catalog_size, high hit rate,
              flat memory. This is the healthy build.
    "order" - keyed on the order id. Every order id is unique, so the cache never
              hits and never stops growing. Reaches the container memory limit in
              a few minutes.

    Nothing in the container names this as a fault. The failure has to be reasoned
    out from the cache hit rate collapsing, the entry count climbing without bound,
    and the task definition diff.
  EOT
  type        = string
  default     = "sku"

  validation {
    condition     = contains(["sku", "order"], var.cache_key_mode)
    error_message = "cache_key_mode must be \"sku\" or \"order\"."
  }
}

variable "target_order_rate" {
  description = <<-EOT
    Orders processed per second. Drives how fast the fault develops: each cached
    quote is roughly 20 KB, so 55/s retains about 1.1 MB/s in "order" mode and
    reaches the 400 MB container limit in roughly five minutes.
  EOT
  type        = number
  default     = 55
}

variable "catalog_size" {
  description = "Number of distinct SKUs. In \"sku\" mode this is the cache's upper bound, so it is what keeps memory flat."
  type        = number
  default     = 120
}

variable "desired_count" {
  description = "Tasks to run. Set to 0 to halt a crash loop without tearing anything down - investigations already opened stay readable."
  type        = number
  default     = 1
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
    "OutOfMemoryError" container reason rather than a platform-level task failure.
  EOT
  type        = number
  default     = 400
}

variable "event_rules" {
  description = <<-EOT
    EventBridge rules that feed the bridge Lambda, as name => event pattern JSON.
    Empty means "use the demo's ECS task-stopped rule" (see local.event_rules).

    The Lambda forwards whatever it receives without interpreting it, so this map
    is the only thing that decides which signals reach the agent. Adding ALB
    target health, container crashes, latency alarms or error-rate alarms is an
    entry here, not a code change:

      event_rules = {
        target-unhealthy = jsonencode({
          source        = ["aws.elasticloadbalancing"]
          "detail-type" = ["ELB Target Health Change"]
        })
        latency-alarm = jsonencode({
          source        = ["aws.cloudwatch"]
          "detail-type" = ["CloudWatch Alarm State Change"]
          detail        = { state = { value = ["ALARM"] } }
        })
      }
  EOT
  type        = map(string)
  default     = {}
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
