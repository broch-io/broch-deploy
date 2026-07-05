# ECS Fargate cluster, task definition, service, ALB, ACM cert, IAM.

# ─── ACM cert covering apex + wildcard ───────────────────────────────────────

resource "aws_acm_certificate" "broch" {
  domain_name               = var.wildcard_hostname
  subject_alternative_names = ["*.${var.wildcard_hostname}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.broch.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id = var.route53_zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "broch" {
  certificate_arn         = aws_acm_certificate.broch.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ─── ALB ─────────────────────────────────────────────────────────────────────

resource "aws_lb" "broch" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  # Enable HTTP/2 by default; Broch's tunnel WebSockets work over HTTP/1.1 upgrade.
}

resource "aws_lb_target_group" "broch" {
  name        = "${var.name_prefix}-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip" # required for Fargate

  health_check {
    enabled             = true
    path                = "/healthz"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # Long deregistration delay would slow rolling deploys; 30s is plenty for
  # this stateless front door (tunnel state lives in Postgres).
  deregistration_delay = 30
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.broch.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.broch.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.broch.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.broch.arn
  }
}

# ─── DNS ─────────────────────────────────────────────────────────────────────

resource "aws_route53_record" "apex" {
  zone_id = var.route53_zone_id
  name    = var.wildcard_hostname
  type    = "A"

  alias {
    name                   = aws_lb.broch.dns_name
    zone_id                = aws_lb.broch.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "wildcard" {
  zone_id = var.route53_zone_id
  name    = "*.${var.wildcard_hostname}"
  type    = "A"

  alias {
    name                   = aws_lb.broch.dns_name
    zone_id                = aws_lb.broch.zone_id
    evaluate_target_health = true
  }
}

# ─── IAM ─────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "task_execution" {
  name = "${var.name_prefix}-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

# Baseline ECS permissions: pull from ECR, push logs to CloudWatch.
resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Custom permissions: read the secrets we created above. Scope tight to just
# this stack's secrets — don't open the door to every secret in the account.
resource "aws_iam_role_policy" "task_execution_secrets" {
  name = "${var.name_prefix}-secrets-read"
  role = aws_iam_role.task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]
      Resource = [
        aws_secretsmanager_secret.master_key.arn,
        aws_secretsmanager_secret.connection_string.arn,
        aws_secretsmanager_secret.auth_client_secret.arn,
      ]
    }]
  })
}

# ─── CloudWatch logs ─────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "broch" {
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = 30
}

# ─── ECS cluster, task, service ──────────────────────────────────────────────

resource "aws_ecs_cluster" "broch" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_task_definition" "broch" {
  family                   = "${var.name_prefix}-broch"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn

  container_definitions = jsonencode([{
    name      = "broch"
    image     = var.broch_image
    essential = true

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    environment = [
      { name = "ASPNETCORE_ENVIRONMENT", value = "Production" },
      { name = "ASPNETCORE_URLS", value = "http://0.0.0.0:8080" },
      { name = "API__WILDCARDHOSTNAME", value = var.wildcard_hostname },
      { name = "DATABASE__PROVIDER", value = "PostgreSQL" },
      # Identity provider — part of the boot floor (the client secret is injected
      # separately via Secrets Manager below). Unused provider-specific values
      # stay blank and are ignored by the server.
      { name = "AUTHENTICATION__PROVIDER", value = var.auth_provider },
      { name = "AUTHENTICATION__CLIENTID", value = var.auth_client_id },
      { name = "AUTHENTICATION__ADMINROLES", value = var.auth_admin_roles },
      { name = "AUTHENTICATION__DOMAIN", value = var.auth_domain },
      { name = "AUTHENTICATION__TENANTID", value = var.auth_tenant_id },
      { name = "AUTHENTICATION__INSTANCE", value = var.auth_instance },
      { name = "AUTHENTICATION__AUTHORITY", value = var.auth_authority },
      { name = "AUTHENTICATION__AUDIENCE", value = var.auth_audience },
    ]

    secrets = [
      {
        name      = "BROCH_MASTER_KEY"
        valueFrom = aws_secretsmanager_secret.master_key.arn
      },
      {
        name      = "ConnectionStrings__BrochConnection"
        valueFrom = aws_secretsmanager_secret.connection_string.arn
      },
      {
        name      = "AUTHENTICATION__CLIENTSECRET"
        valueFrom = aws_secretsmanager_secret.auth_client_secret.arn
      },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.broch.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "broch"
      }
    }

    healthCheck = {
      # bash /dev/tcp probe, not curl: broch images ≤1.23.0 ship no curl/wget
      # (bash is present in the Debian-based aspnet image).
      command     = ["CMD", "bash", "-c", "exec 3<>/dev/tcp/localhost/8080 && printf 'GET /healthz HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n' >&3 && head -n1 <&3 | grep -q ' 200 '"]
      interval    = 30
      timeout     = 10
      retries     = 3
      startPeriod = 60
    }
  }])
}

resource "aws_ecs_service" "broch" {
  name             = "${var.name_prefix}-service"
  cluster          = aws_ecs_cluster.broch.id
  task_definition  = aws_ecs_task_definition.broch.arn
  desired_count    = 1
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_task.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.broch.arn
    container_name   = "broch"
    container_port   = 8080
  }

  # ALB needs at least one healthy target before the service is marked stable.
  # Crank this only if your broch startup is unusually slow.
  health_check_grace_period_seconds = 120

  depends_on = [aws_lb_listener.https]

  lifecycle {
    # The task definition gets re-rendered on every apply because of the
    # `image` reference. Don't trigger a no-op deploy if only that changed
    # without the underlying image actually moving.
    ignore_changes = [task_definition]
  }
}
