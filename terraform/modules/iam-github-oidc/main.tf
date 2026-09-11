# terraform/modules/iam-github-oidc/main.tf
# GitHub Actions -> AWS via OIDC. NO long-lived access keys anywhere.
# GitHub mints a short-lived JWT; AWS STS exchanges it for temporary creds.

# One provider per AWS account. If it already exists, reference it and skip.
resource "aws_iam_openid_connect_provider" "github" {
  count           = var.create_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  # Thumbprint of GitHub's OIDC certificate root. AWS relies on this cert
  # chain; the value below is GitHub's current DigiCert root thumbprint.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  tags            = var.tags
}

data "aws_iam_openid_connect_provider" "existing" {
  count = var.create_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  provider_arn = var.create_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.existing[0].arn
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }
    # Only tokens for this repo + these branches/environments may assume the role.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for s in var.allowed_subjects : "repo:${var.github_org}/${var.github_repo}:${s}"]
    }
  }
}

resource "aws_iam_role" "deployer" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

# Least-privilege inline policy — narrow to exactly what deploys need.
data "aws_iam_policy_document" "deployer" {
  # ECR: push images
  statement {
    sid = "ECRPush"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:DescribeRepositories",
      "ecr:DescribeImages",
    ]
    resources = ["*"]
  }
  # ECS: register new task defs + update service
  statement {
    sid = "ECSDeploy"
    actions = [
      "ecs:DescribeServices",
      "ecs:DescribeTaskDefinition",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
      "ecs:RegisterTaskDefinition",
      "ecs:UpdateService",
      "ecs:DeregisterTaskDefinition",
    ]
    resources = ["*"]
  }
  # PassRole: allow ECS execution + task roles to be attached to new task defs
  statement {
    sid       = "PassECSRoles"
    actions   = ["iam:PassRole"]
    resources = var.passable_role_arns
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
  # CloudWatch Logs read for smoke checks
  statement {
    sid       = "LogsRead"
    actions   = ["logs:DescribeLogStreams", "logs:GetLogEvents", "logs:FilterLogEvents"]
    resources = ["*"]
  }
  # Terraform S3 state + DynamoDB lock (scoped to the state bucket/table)
  statement {
    sid       = "TFState"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.tf_state_bucket}",
      "arn:aws:s3:::${var.tf_state_bucket}/*",
    ]
  }
  statement {
    sid       = "TFLock"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = ["arn:aws:dynamodb:*:*:table/${var.tf_lock_table}"]
  }
}

resource "aws_iam_role_policy" "deployer" {
  name   = "${var.role_name}-inline"
  role   = aws_iam_role.deployer.id
  policy = data.aws_iam_policy_document.deployer.json
}

# For terraform plan/apply of ALL infra we need broader read + specific write.
# In a real prod setup, split into plan-only and apply roles.
resource "aws_iam_role_policy_attachment" "terraform_admin" {
  count      = var.attach_admin_for_terraform ? 1 : 0
  role       = aws_iam_role.deployer.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}
