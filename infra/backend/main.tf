# Doqto backend: ECS Fargate (FastAPI+WS) behind ALB on api.doqto.ai (+ admin.doqto.ai),
# RDS Postgres 15, ElastiCache Redis 7 (TLS), media S3 bucket.
# Usage: ./deploy.sh (builds image, pushes to ECR, applies, bounces service).
# Runs in the default VPC's public subnets with SG isolation — no NAT cost.
# ponytail: single-AZ, one task; add AZs/replicas when there's real traffic.

terraform {
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = var.aws_profile
}

variable "aws_profile" {
  default = "loki-doqto"
}

variable "super_admin" {
  type      = map(string) # PHONE, NAME, NPI, EMAIL, PASSWORD
  sensitive = true
}

# google-auth credential JSON for FCM HTTP v1 (service-account key or
# workload-identity external_account). Empty keeps PUSH_PROVIDER=log.
variable "fcm_service_account_json" {
  type      = string
  sensitive = true
  default   = ""
}


data "aws_caller_identity" "me" {}
data "aws_vpc" "default" {
  default = true
}
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  name   = "doqto-backend"
  domain = "api.doqto.ai"
  port   = 8000
}

# ---------- secrets ----------

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "random_password" "redis" {
  length  = 40
  special = false
}

resource "random_password" "jwt" {
  length  = 64
  special = false
}

resource "random_bytes" "message_key" {
  length = 32
}

locals {
  database_url = "postgresql+asyncpg://doqto:${random_password.db.result}@${aws_db_instance.db.address}:5432/doqto"
  redis_url    = "rediss://:${random_password.redis.result}@${aws_elasticache_replication_group.redis.primary_endpoint_address}:6379/0"
  secrets = {
    DATABASE_URL             = local.database_url
    REDIS_URL                = local.redis_url
    JWT_SECRET               = random_password.jwt.result
    MESSAGE_ENCRYPTION_KEY   = random_bytes.message_key.base64
    SUPER_ADMIN_PHONE        = var.super_admin["PHONE"]
    SUPER_ADMIN_NAME         = var.super_admin["NAME"]
    SUPER_ADMIN_NPI          = var.super_admin["NPI"]
    SUPER_ADMIN_EMAIL        = var.super_admin["EMAIL"]
    SUPER_ADMIN_PASSWORD     = var.super_admin["PASSWORD"]
    FCM_SERVICE_ACCOUNT_JSON = var.fcm_service_account_json
  }
}

resource "aws_ssm_parameter" "secret" {
  for_each = local.secrets
  name     = "/doqto/backend/${each.key}"
  type     = "SecureString"
  value    = each.value
}

# ---------- security groups ----------

resource "aws_security_group" "alb" {
  name   = "${local.name}-alb"
  vpc_id = data.aws_vpc.default.id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "app" {
  name   = "${local.name}-app"
  vpc_id = data.aws_vpc.default.id
  ingress {
    from_port       = local.port
    to_port         = local.port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  ingress { # admin panel
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db" {
  name   = "${local.name}-db"
  vpc_id = data.aws_vpc.default.id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
}

resource "aws_security_group" "redis" {
  name   = "${local.name}-redis"
  vpc_id = data.aws_vpc.default.id
  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
}

# ---------- data stores ----------

resource "aws_db_instance" "db" {
  identifier                = local.name
  engine                    = "postgres"
  engine_version            = "15"
  instance_class            = "db.t4g.micro"
  allocated_storage         = 20
  storage_type              = "gp3"
  db_name                   = "doqto"
  username                  = "doqto"
  password                  = random_password.db.result
  vpc_security_group_ids    = [aws_security_group.db.id]
  storage_encrypted         = true
  backup_retention_period   = 7
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name}-final"
  apply_immediately         = true
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = local.name
  description                = "Doqto backend redis"
  engine                     = "redis"
  engine_version             = "7.1"
  node_type                  = "cache.t4g.micro"
  num_cache_clusters         = 1
  port                       = 6379
  security_group_ids         = [aws_security_group.redis.id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis.result
  auto_minor_version_upgrade = true
}

# ---------- media bucket ----------

resource "aws_s3_bucket" "media" {
  bucket = "doqto-media-${data.aws_caller_identity.me.account_id}"
}

resource "aws_s3_bucket_public_access_block" "media" {
  bucket                  = aws_s3_bucket.media.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  bucket = aws_s3_bucket.media.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------- certificate (api.doqto.ai) ----------

resource "aws_acm_certificate" "api" {
  domain_name       = local.domain
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "api" {
  certificate_arn = aws_acm_certificate.api.arn
}

output "acm_validation_records" {
  value = aws_acm_certificate.api.domain_validation_options
}

# ---------- load balancer ----------

resource "aws_lb" "api" {
  name               = local.name
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids
  idle_timeout       = 300 # long-lived websockets
}

resource "aws_lb_target_group" "api" {
  name        = local.name
  port        = local.port
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"
  health_check {
    path                = "/health"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.api.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.api.certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.api.arn
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

# ---------- ECR + ECS ----------

resource "aws_ecr_repository" "api" {
  name                 = local.name
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${local.name}"
  retention_in_days = 90
}

resource "aws_iam_role" "exec" {
  name = "${local.name}-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "exec" {
  role       = aws_iam_role.exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "exec_ssm" {
  name = "read-secrets"
  role = aws_iam_role.exec.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameters"]
      Resource = [for p in aws_ssm_parameter.secret : p.arn]
    }]
  })
}

resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = aws_iam_role.exec.assume_role_policy
}

resource "aws_iam_role_policy" "task" {
  name = "app-aws-access"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketLocation", "s3:CreateBucket", "s3:HeadBucket"]
        Resource = [aws_s3_bucket.media.arn, "${aws_s3_bucket.media.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["transcribe:StartMedicalTranscriptionJob", "transcribe:GetMedicalTranscriptionJob", "transcribe:StartTranscriptionJob", "transcribe:GetTranscriptionJob"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_ecs_cluster" "main" {
  name = local.name
}

resource "aws_ecs_task_definition" "api" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.exec.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name         = "api"
    image        = "${aws_ecr_repository.api.repository_url}:latest"
    essential    = true
    command      = ["sh", "-c", "alembic upgrade head && uvicorn main:app --host 0.0.0.0 --port ${local.port} --workers 2"]
    portMappings = [{ containerPort = local.port, protocol = "tcp" }]
    environment = [
      { name = "ENVIRONMENT", value = "production" },
      { name = "AWS_REGION", value = "us-east-1" },
      { name = "AWS_S3_BUCKET_NAME", value = aws_s3_bucket.media.bucket },
      { name = "ALLOWED_ORIGINS", value = "https://doqto.ai,https://www.doqto.ai" },
      { name = "NETWORK_DM_ENABLED", value = "true" },
      { name = "PUSH_PROVIDER", value = var.fcm_service_account_json == "" ? "log" : "fcm" },
      { name = "FCM_PROJECT_ID", value = "doqto-90684" },
      # Firebase brokers every sign-in (phone, Google, Facebook, Apple). Only
      # the project id is needed: ID tokens are verified against Google's
      # public certs, so there is no secret here. Same project as FCM.
      { name = "FIREBASE_PROJECT_ID", value = "doqto-90684" },
    ]
    secrets = [for k, p in aws_ssm_parameter.secret : { name = k, valueFrom = p.arn }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.api.name
        awslogs-region        = "us-east-1"
        awslogs-stream-prefix = "api"
      }
    }
  }])
}

resource "aws_ecs_service" "api" {
  # TG must be attached to the ALB (via the listener) before service creation.
  depends_on             = [aws_lb_listener.https]
  name                   = local.name
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.api.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = true # default VPC public subnets; no NAT
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = local.port
  }
}

# ---------- CI deploy user (GitHub Actions) ----------
# ponytail: access keys in repo secrets; switch to OIDC if keys become a concern.

resource "aws_iam_user" "ci" {
  name = "${local.name}-ci"
}

resource "aws_iam_user_policy" "ci" {
  name = "deploy"
  user = aws_iam_user.ci.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage",
          "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"
        ]
        Resource = aws_ecr_repository.api.arn
      },
      {
        Effect   = "Allow"
        Action   = ["ecs:UpdateService", "ecs:DescribeServices"]
        Resource = aws_ecs_service.api.id
      }
    ]
  })
}

resource "aws_iam_access_key" "ci" {
  user = aws_iam_user.ci.name
}

output "ci_access_key_id" {
  value = aws_iam_access_key.ci.id
}

output "ci_secret_access_key" {
  value     = aws_iam_access_key.ci.secret
  sensitive = true
}

output "alb_dns" {
  value = aws_lb.api.dns_name
}

output "ecr_repo" {
  value = aws_ecr_repository.api.repository_url
}

output "api_url" {
  value = "https://${local.domain}"
}

# ---------- admin panel (admin.doqto.ai) ----------
# Next.js server on the same cluster + ALB; host-header rule routes to it.
# ponytail: shares the exec role and app SG (port 3000 opened inline above).

locals {
  admin_name   = "doqto-admin"
  admin_domain = "admin.doqto.ai"
  admin_port   = 3000
}


resource "aws_acm_certificate" "admin" {
  domain_name       = local.admin_domain
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "admin" {
  certificate_arn = aws_acm_certificate.admin.arn
}

output "admin_acm_validation_records" {
  value = aws_acm_certificate.admin.domain_validation_options
}

resource "aws_lb_listener_certificate" "admin" {
  listener_arn    = aws_lb_listener.https.arn
  certificate_arn = aws_acm_certificate_validation.admin.certificate_arn
}

resource "aws_lb_target_group" "admin" {
  name        = local.admin_name
  port        = local.admin_port
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"
  health_check {
    path                = "/login"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener_rule" "admin" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.admin.arn
  }
  condition {
    host_header {
      values = [local.admin_domain]
    }
  }
}

resource "aws_ecr_repository" "admin" {
  name                 = local.admin_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

resource "aws_cloudwatch_log_group" "admin" {
  name              = "/ecs/${local.admin_name}"
  retention_in_days = 90
}

resource "aws_ecs_task_definition" "admin" {
  family                   = local.admin_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.exec.arn

  container_definitions = jsonencode([{
    name         = "admin"
    image        = "${aws_ecr_repository.admin.repository_url}:latest"
    essential    = true
    portMappings = [{ containerPort = local.admin_port, protocol = "tcp" }]
    environment = [
      { name = "API_BASE_URL", value = "https://${local.domain}" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.admin.name
        awslogs-region        = "us-east-1"
        awslogs-stream-prefix = "admin"
      }
    }
  }])
}

resource "aws_ecs_service" "admin" {
  depends_on      = [aws_lb_listener_rule.admin]
  name            = local.admin_name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.admin.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.admin.arn
    container_name   = "admin"
    container_port   = local.admin_port
  }
}

output "admin_url" {
  value = "https://${local.admin_domain}"
}
