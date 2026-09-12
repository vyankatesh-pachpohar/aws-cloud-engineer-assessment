# terraform/modules/secrets/main.tf
# Generate a random DB password and store it in AWS Secrets Manager.
# ECS references this ARN in the task definition -> injected as env var at
# container start. The password never appears in Terraform state as plaintext
# beyond this module and is never logged.

resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#$%*_+-=" # exclude chars that trip up shells / URLs
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.name}/db-password"
  description             = "Master password for RDS ${var.name}"
  recovery_window_in_days = 7 # soft-delete window; 0 in dev if you must
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = random_password.db.result
}
