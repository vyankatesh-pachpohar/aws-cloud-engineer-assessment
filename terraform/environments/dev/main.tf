# terraform/environments/dev/main.tf
# Root config for the DEV environment. Composes every module.

locals {
  name = "${var.project}-${var.environment}"
  common_tags = {
    App = var.project
    Env = var.environment
  }
}

data "aws_caller_identity" "me" {}

# ------------- VPC -------------
module "vpc" {
  source             = "../../modules/vpc"
  name               = local.name
  cidr               = var.vpc_cidr
  az_count           = 2
  nat_per_az         = false           # cost: one NAT in dev
  enable_flow_logs   = true
  log_retention_days = 14
  tags               = local.common_tags
}

# ------------- ECR (image repo) -------------
module "ecr" {
  source       = "../../modules/ecr"
  name         = local.name
  force_delete = true                   # dev only; false in prod
  tags         = local.common_tags
}

# ------------- Secrets (DB password) -------------
module "secrets" {
  source = "../../modules/secrets"
  name   = local.name
  tags   = local.common_tags
}

# ------------- S3 bucket for ALB logs -------------
module "logs_bucket" {
  source              = "../../modules/s3"
  bucket_name         = "${local.name}-logs-${data.aws_caller_identity.me.account_id}"
  force_destroy       = true            # dev only
  log_expiration_days = 90       # > max transition day (60d Glacier); AWS validates this at apply time
  tags                = local.common_tags
}

# ------------- ALB -------------
module "alb" {
  source              = "../../modules/alb"
  name                = local.name
  vpc_id              = module.vpc.vpc_id
  public_subnet_ids   = module.vpc.public_subnet_ids
  certificate_arn     = var.acm_certificate_arn
  access_logs_bucket  = module.logs_bucket.bucket_id
  deletion_protection = false           # dev
  tags                = local.common_tags
}

# ------------- RDS PostgreSQL -------------
# Note: RDS module no longer accepts allowed_source_sg_id — the ingress
# rule that lets ECS tasks reach RDS on 5432 is created below as a
# standalone resource. This breaks what would otherwise be a circular
# dependency between the RDS and ECS modules (ecs needs rds.endpoint;
# rds would need ecs.task_sg_id).
module "rds" {
  source                = "../../modules/rds"
  name                  = local.name
  vpc_id                = module.vpc.vpc_id
  private_subnet_ids    = module.vpc.private_subnet_ids
  instance_class        = "db.t3.micro"
  engine_version        = "16.15"       # pinned; RDS drops old minor versions periodically
  allocated_storage     = 20
  multi_az              = false         # cost: false in dev, true in prod
  backup_retention_days = 1
  deletion_protection   = false
  master_password       = module.secrets.db_password
  tags                  = local.common_tags
}

# ------------- ECS Fargate service -------------
module "ecs" {
  source                  = "../../modules/ecs"
  name                    = local.name
  region                  = var.region
  vpc_id                  = module.vpc.vpc_id
  private_subnet_ids      = module.vpc.private_subnet_ids
  alb_sg_id               = module.alb.alb_sg_id
  target_group_arn        = module.alb.target_group_arn
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix

  # First apply uses a public bootstrap image so ECS has something to pull
  # before our ECR repo is populated. CI overrides this with our image URI.
  container_image = var.container_image_tag == "bootstrap" ? "public.ecr.aws/docker/library/nginx:alpine" : "${module.ecr.repository_url}:${var.container_image_tag}"
  container_port  = var.container_image_tag == "bootstrap" ? 80 : 8000

  desired_count = 2
  min_capacity  = 2
  max_capacity  = 6
  task_cpu      = 512
  task_memory   = 1024

  environment = {
    APP_ENV   = var.environment
    LOG_LEVEL = "INFO"
    DB_HOST   = module.rds.endpoint
    DB_PORT   = tostring(module.rds.port)
    DB_NAME   = module.rds.db_name
    DB_USER   = "orders"
  }

  secrets = {
    DB_PASSWORD = module.secrets.db_secret_arn
  }
  secret_arns = [module.secrets.db_secret_arn]

  log_retention_days = 30
  enable_exec        = true             # allows `aws ecs execute-command`
  tags               = local.common_tags
}

# ------------- Cross-module SG ingress: ECS tasks → RDS ------------
# Standalone rule kept at root to avoid the ecs↔rds module cycle. Depends
# only on the two SG IDs; Terraform creates it after both modules' SGs exist.
resource "aws_vpc_security_group_ingress_rule" "rds_from_ecs" {
  security_group_id            = module.rds.sg_id
  referenced_security_group_id = module.ecs.task_sg_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "Postgres from ECS tasks"

  tags = merge(local.common_tags, { Name = "${local.name}-rds-from-ecs" })
}

# ------------- WAF -------------
module "waf" {
  source     = "../../modules/waf"
  name       = local.name
  alb_arn    = module.alb.alb_arn
  rate_limit = 2000
  tags       = local.common_tags
}

# ------------- GitHub Actions OIDC role -------------
module "github_oidc" {
  source                     = "../../modules/iam-github-oidc"
  role_name                  = "${local.name}-github-actions"
  github_org                 = var.github_org
  github_repo                = var.github_repo
  # Allowed subject patterns from this repo. StringLike + repo prefix means
  # each pattern is scoped to this repo — a fork or a different repo cannot
  # assume this role even with a valid GitHub token.
  #
  # The trailing "*" is a permissive fallback that still stays repo-scoped;
  # it covers cases the specific patterns miss (job matrix, manual dispatch,
  # environment not yet registered on GitHub, etc.) In real prod I'd narrow
  # this to the exact events after observing what actually needs access.
  allowed_subjects = [
    "ref:refs/heads/main",
    "ref:refs/heads/*",
    "pull_request",
    "environment:${var.environment}",
    "*",
  ]
  passable_role_arns         = [module.ecs.execution_role_arn, module.ecs.task_role_arn]
  tf_state_bucket            = var.tf_state_bucket
  tf_lock_table              = var.tf_lock_table
  create_provider            = true
  attach_admin_for_terraform = true
  tags                       = local.common_tags
}

# ------------- Monitoring -------------
module "monitoring" {
  source                  = "../../modules/monitoring"
  name                    = local.name
  region                  = var.region
  alert_emails            = var.alert_emails
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  ecs_cluster_name        = module.ecs.cluster_name
  ecs_service_name        = module.ecs.service_name
  rds_instance_id         = local.name
  tags                    = local.common_tags
}
