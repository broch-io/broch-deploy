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

# drop_invalid_header_fields stays off: it strips any header with an underscore, and tunnels carry
# customers' own application headers.
# trivy:ignore:AWS-0052
resource "aws_lb" "broch" {
  name = "${var.name_prefix}-alb"
  # The internet-facing ALB is the service endpoint.
  # trivy:ignore:AWS-0053
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

  # A long deregistration delay would slow every deploy; 30s gives in-flight
  # requests time to drain from the old task.
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

locals {
  # The plain settings Broch reads (the secrets come from Secrets Manager on the task). One map so
  # the configuration contract check (scripts/config-contract.py) can render exactly what this module
  # sends and ask Broch whether it would start with it.
  broch_environment = {
    ASPNETCORE_ENVIRONMENT = "Production"
    ASPNETCORE_URLS        = "http://0.0.0.0:8080"
    API__WILDCARDHOSTNAME  = var.wildcard_hostname
    # Trusted-proxy CIDRs so the ALB's X-Forwarded-For/-Proto are honored (broch trusts only
    # loopback by default). The ALB fronts the task from this VPC's subnets, and the task's
    # security group only admits the ALB on 8080. First boot only — the value in
    # Admin -> Share Settings wins afterwards.
    API__TRUSTEDPROXYCIDRS = var.vpc_cidr
    DATABASE__PROVIDER     = "PostgreSQL"
    # Identity provider — part of the boot floor (the client secret is injected separately via
    # Secrets Manager). Unused provider-specific values stay blank and are ignored by the server.
    AUTHENTICATION__PROVIDER   = var.auth_provider
    AUTHENTICATION__CLIENTID   = var.auth_client_id
    AUTHENTICATION__ADMINROLES = var.auth_admin_roles
    AUTHENTICATION__DOMAIN     = var.auth_domain
    AUTHENTICATION__TENANTID   = var.auth_tenant_id
    AUTHENTICATION__INSTANCE   = var.auth_instance
    AUTHENTICATION__AUTHORITY  = var.auth_authority
    AUTHENTICATION__AUDIENCE   = var.auth_audience
  }
}

resource "aws_ecs_task_definition" "broch" {
  family                   = "${var.name_prefix}-broch"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn

  lifecycle {
    # Broch refuses to start without each provider's required values, and only after the
    # database is migrated. Fail the plan instead. These mirror the server's startup checks;
    # an explicit auth_authority waives the domain/instance/tenant checks, as it does there.
    # Provider match is case-insensitive, as Broch binds it.
    precondition {
      condition     = trimspace(var.auth_client_id) != "" && trimspace(var.auth_client_secret) != ""
      error_message = "auth_client_id and auth_client_secret are required: Broch refuses to start with a provider but no client credentials."
    }
    precondition {
      condition     = lower(trimspace(var.auth_provider)) != "auth0" || trimspace(var.auth_audience) != ""
      error_message = "auth_audience is required when auth_provider is Auth0: set it to the Identifier of the Auth0 API your Broch application has user access to."
    }
    precondition {
      condition     = lower(trimspace(var.auth_provider)) != "oidc" || trimspace(var.auth_authority) != ""
      error_message = "auth_authority is required when auth_provider is Oidc: set it to your IdP's issuer URL."
    }
    precondition {
      condition = (!contains(["auth0", "okta"], lower(trimspace(var.auth_provider)))
      || trimspace(var.auth_authority) != "" || trimspace(var.auth_domain) != "")
      error_message = "auth_domain is required when auth_provider is Auth0 or Okta (e.g. your-tenant.auth0.com), unless you set auth_authority."
    }
    precondition {
      condition = (!contains(["azuread", "entraexternalid"], lower(trimspace(var.auth_provider)))
        || trimspace(var.auth_authority) != ""
      || (trimspace(var.auth_instance) != "" && trimspace(var.auth_tenant_id) != ""))
      error_message = "auth_instance and auth_tenant_id are required when auth_provider is AzureAd or EntraExternalId, unless you set auth_authority (AzureAd's instance is https://login.microsoftonline.com/, EntraExternalId's is https://<tenant>.ciamlogin.com/)."
    }
  }

  container_definitions = jsonencode([{
    name      = "broch"
    image     = var.broch_image
    essential = true

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    environment = [for name, value in local.broch_environment : { name = name, value = value }]

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
    # Terraform registers a new task-definition revision when its inputs change
    # (image, CPU/memory, environment), but the service stays on the revision it
    # runs. Deploy a new revision with `aws ecs update-service` (README, "Pulling
    # a new broch image").
    ignore_changes = [task_definition]
  }
}
