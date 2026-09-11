# terraform/modules/rds/main.tf
# RDS PostgreSQL.
#
# Design decisions:
#  * Private subnets only, no public IP. There is no path from the internet.
#  * Security group allows 5432 *only* from the ECS task security group.
#  * Storage encrypted at rest (KMS aws/rds by default), in transit via TLS
#    (Postgres SSL is on by default; app can be pinned via sslmode=require).
#  * Automated backups + PIT recovery via backup_retention_period.
#  * Multi-AZ toggled per environment (dev=false, prod=true).
#  * Deletion protection + final snapshot in prod.
#  * Password is generated here and pushed to the Secrets Manager module.

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-subnets"
  subnet_ids = var.private_subnet_ids
  tags       = merge(var.tags, { Name = "${var.name}-subnets" })
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-rds"
  description = "RDS Postgres — reachable only from ECS tasks"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Postgres from ECS tasks"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.allowed_source_sg_id]
  }

  # No egress needed for RDS itself, but AWS requires a rule.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-rds-sg" })
}

# Parameter group: enforce SSL and log slow queries.
resource "aws_db_parameter_group" "pg" {
  name   = "${var.name}-pg"
  family = "postgres${split(".", var.engine_version)[0]}"

  parameter { name = "rds.force_ssl"                 value = "1" }
  parameter { name = "log_min_duration_statement"    value = "1000" }        # >1s
  parameter { name = "log_connections"               value = "1" }
  parameter { name = "log_disconnections"            value = "1" }

  tags = var.tags
}

resource "aws_db_instance" "this" {
  identifier                 = var.name
  engine                     = "postgres"
  engine_version             = var.engine_version
  instance_class             = var.instance_class

  allocated_storage          = var.allocated_storage
  max_allocated_storage      = var.max_allocated_storage    # storage autoscaling
  storage_type               = "gp3"
  storage_encrypted          = true

  db_name                    = var.db_name
  username                   = var.master_username
  password                   = var.master_password           # from Secrets Manager

  db_subnet_group_name       = aws_db_subnet_group.this.name
  vpc_security_group_ids     = [aws_security_group.rds.id]
  publicly_accessible        = false
  multi_az                   = var.multi_az

  parameter_group_name       = aws_db_parameter_group.pg.name

  backup_retention_period    = var.backup_retention_days
  backup_window              = "03:00-04:00"
  maintenance_window         = "Mon:04:00-Mon:05:00"

  deletion_protection        = var.deletion_protection
  skip_final_snapshot        = !var.deletion_protection
  final_snapshot_identifier  = var.deletion_protection ? "${var.name}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}" : null

  performance_insights_enabled          = var.performance_insights
  performance_insights_retention_period = var.performance_insights ? 7 : null
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true
  apply_immediately          = false        # apply in the maintenance window in prod

  lifecycle {
    ignore_changes = [final_snapshot_identifier]    # timestamp differs every plan
  }

  tags = merge(var.tags, { Name = var.name })
}
