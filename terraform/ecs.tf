locals {
  # Bumped alongside the cache change so the task definition diff carries a
  # version change too, which is the signal the agent looks for when it asks
  # "what shipped just before this broke?".
  app_version = var.cache_key_mode == "order" ? "1.5.0" : "1.4.2"
}

resource "aws_ecs_cluster" "this" {
  name = var.name_prefix

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enhanced" : "disabled"
  }
}

resource "aws_cloudwatch_log_group" "service" {
  name              = "/ecs/${var.name_prefix}/order-processor"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "task_execution_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${var.name_prefix}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.task_execution_assume.json
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "order_processor" {
  family                   = "${var.name_prefix}-order-processor"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name  = "order-processor"
      image = "public.ecr.aws/docker/library/python:3.12-slim"
      # Hard limit below the task limit, so the container is killed before the
      # platform reclaims the whole task.
      memory    = var.container_memory_hard
      essential = true

      command = [
        "python3",
        "-u",
        "-c",
        file("${path.module}/app/order_processor.py"),
      ]

      # The agent can read all of this from the task definition, so nothing here
      # may name the fault. cache_key_mode is the only meaningful difference
      # between the healthy and broken revisions.
      environment = [
        { name = "APP_VERSION", value = local.app_version },
        { name = "CACHE_KEY_MODE", value = var.cache_key_mode },
        { name = "TARGET_ORDER_RATE", value = tostring(var.target_order_rate) },
        { name = "CATALOG_SIZE", value = tostring(var.catalog_size) },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.service.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "order-processor"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "order_processor" {
  name            = "order-processor"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.order_processor.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true
  }

  # Left off on purpose. With rollback enabled ECS would heal the bad deployment
  # itself and the crash loop the agent is meant to investigate would disappear.
  deployment_circuit_breaker {
    enable   = false
    rollback = false
  }
}
