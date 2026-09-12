# terraform/modules/ecs/main.tf
# ECS Fargate cluster + service.
#
# Design decisions:
#  * Fargate (not EC2) - no OS patching, per-second billing, matches assessed
#    "server-based/containerized" requirement without adding EC2 management.
#  * Two IAM roles:
#      execution_role  - ECS agent uses it to pull ECR images and read secrets
#                        BEFORE the container starts (log driver, secrets mgr).
#      task_role       - the running container assumes it (AWS API calls from
#                        inside the app). Empty here because the app only talks
#                        to RDS; extend as needed (S3, SQS, ...).
#  * Secrets Manager -> env var (secrets = [...]) - the DB password is never
#    baked into the image nor stored in plaintext env vars.
#  * Log driver awslogs -> CloudWatch (JSON lines from the app, queryable).
#  * Auto scaling on CPU 60% target and per-target request count.
#  * lifecycle ignore_changes on desired_count + task_definition so the CI/CD
#    pipeline can update the image without Terraform reverting it on next apply.

resource "aws_ecs_cluster" "this" {
  name = "${var.name}-cluster"
  setting {
    name  = "containerInsights"
    value = "enabled" # per-service CPU/mem/net metrics
  }
  tags = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = var.min_on_demand # ensure baseline on-demand tasks
  }
}

# ---------- CloudWatch log group ----------
resource "aws_cloudwatch_log_group" "app" {
  name              = "/aws/ecs/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# ---------- security group for tasks ----------
resource "aws_security_group" "tasks" {
  name        = "${var.name}-tasks"
  description = "ECS tasks - only accept traffic from the ALB"
  vpc_id      = var.vpc_id

  ingress {
    description     = "from ALB"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [var.alb_sg_id] # narrower than a CIDR
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] # to RDS, ECR, Secrets Manager, ...
  }

  tags = merge(var.tags, { Name = "${var.name}-tasks-sg" })
}

# ---------- IAM: execution role ----------
data "aws_iam_policy_document" "assume_ecs_tasks" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name}-ecs-exec"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs_tasks.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Least-privilege secrets read: only the specific secret ARN(s).
data "aws_iam_policy_document" "exec_secrets" {
  count = length(var.secret_arns) > 0 ? 1 : 0
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = var.secret_arns
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "exec_secrets" {
  count  = length(var.secret_arns) > 0 ? 1 : 0
  name   = "${var.name}-exec-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.exec_secrets[0].json
}

# ---------- IAM: task role (the running container) ----------
resource "aws_iam_role" "task" {
  name               = "${var.name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs_tasks.json
  tags               = var.tags
}

# Optional extra policies (e.g. S3 write) - attach as needed via var.task_role_policy_arns
resource "aws_iam_role_policy_attachment" "task_extra" {
  for_each   = toset(var.task_role_policy_arns)
  role       = aws_iam_role.task.name
  policy_arn = each.value
}

# ---------- task definition ----------
resource "aws_ecs_task_definition" "app" {
  family                   = var.name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name         = var.name
    image        = var.container_image
    essential    = true
    portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]

    environment = [
      for k, v in var.environment : { name = k, value = v }
    ]

    # Sensitive values (like the DB password) come from Secrets Manager.
    secrets = [
      for k, arn in var.secrets : { name = k, valueFrom = arn }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "app"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "python -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:${var.container_port}/health', timeout=2).status==200 else 1)\""]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 15
    }

    stopTimeout            = 30    # allow graceful shutdown (finish in-flight)
    readonlyRootFilesystem = false # uvicorn writes to /tmp; flip on with a tmpfs if hardened
  }])

  tags = var.tags
}

# ---------- ECS service ----------
resource "aws_ecs_service" "app" {
  name                   = "${var.name}-svc"
  cluster                = aws_ecs_cluster.this.id
  task_definition        = aws_ecs_task_definition.app.arn
  desired_count          = var.desired_count
  launch_type            = "FARGATE"
  platform_version       = "LATEST"
  enable_execute_command = var.enable_exec # ECS Exec for shell-in-container

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false # tasks reach the internet via NAT
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = var.name
    container_port   = var.container_port
  }

  # Rolling deploys with circuit breaker: automatically rolls back a bad deploy.
  deployment_controller { type = "ECS" }
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100 # zero-downtime deploys

  health_check_grace_period_seconds = 60

  # CI/CD will update the task-def image and desired_count; don't fight it.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_iam_role_policy_attachment.execution_managed]
  tags       = var.tags
}

# ---------- auto scaling ----------
resource "aws_appautoscaling_target" "svc" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.svc.resource_id
  scalable_dimension = aws_appautoscaling_target.svc.scalable_dimension
  service_namespace  = aws_appautoscaling_target.svc.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = 60
    predefined_metric_specification { predefined_metric_type = "ECSServiceAverageCPUUtilization" }
    scale_in_cooldown  = 300 # slow to shed: avoids flapping
    scale_out_cooldown = 60  # fast to add: user experience first
  }
}

resource "aws_appautoscaling_policy" "req_per_target" {
  name               = "${var.name}-req"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.svc.resource_id
  scalable_dimension = aws_appautoscaling_target.svc.scalable_dimension
  service_namespace  = aws_appautoscaling_target.svc.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = var.requests_per_target
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      # ALB resource label required by ALBRequestCountPerTarget:
      # app/<alb-name>/<alb-id>/targetgroup/<tg-name>/<tg-id>
      resource_label = "${var.alb_arn_suffix}/${var.target_group_arn_suffix}"
    }
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
