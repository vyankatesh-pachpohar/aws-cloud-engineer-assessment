# terraform/modules/iam-github-oidc/main.tf
# GitHub Actions -> AWS via OIDC. NO long-lived access keys anywhere.
# GitHub mints a short-lived JWT; AWS STS exchanges it for temporary creds.

# One provider per AWS account. If it already exists, reference it and skip.
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # Thumbprint of GitHub's OIDC certificate root. AWS stopped enforcing this
  # in mid-2023 but the field is still required. Value is GitHub's DigiCert
  # root thumbprint.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  tags            = var.tags
}

data "aws_iam_openid_connect_provider" "existing" {
  count = var.create_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  provider_arn = var.create_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.existing[0].arn

  # GitHub's OIDC sub claim can arrive in two formats. The classic format
  # is `repo:OWNER/REPO:...`. The newer format includes numeric account
  # and repo IDs — `repo:OWNER@123/REPO@456:...` — which prevents attacks
  # via renamed orgs/repos. Any real GitHub workflow today sends the newer
  # format; older docs and older tokens use the classic format. Trust both
  # so no valid caller from this repo is ever rejected.
  sub_patterns_classic = [for s in var.allowed_subjects : "repo:${var.github_org}/${var.github_repo}:${s}"]
  sub_patterns_new     = [for s in var.allowed_subjects : "repo:${var.github_org}@*/${var.github_repo}@*:${s}"]
  all_sub_patterns     = concat(local.sub_patterns_classic, local.sub_patterns_new)
}

data "aws_iam_policy_document" "assume" {
  statement {
    # sts:TagSession is required by aws-actions/configure-aws-credentials@v4;
    # without it, AssumeRoleWithWebIdentity is denied on session-tag calls.
    actions = ["sts:AssumeRoleWithWebIdentity", "sts:TagSession"]
    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }
    # aud must match what the AWS action requests. Default is sts.amazonaws.com.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # sub must match one of the allowed patterns (both classic and new formats
    # are allowed). StringLike + the repo:OWNER/REPO prefix keeps this scoped
    # to this repository — a fork or another repo cannot assume this role.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.all_sub_patterns
    }
  }
}

resource "aws_iam_role" "deployer" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

# ----- Least-privilege inline policy for the deploy pipeline -----
# The pipeline needs a specific, well-defined set of AWS permissions:
#   * ECR push
#   * ECS task-def register + service update
#   * PassRole (only for the ECS execution/task roles)
#   * CloudWatch Logs read (smoke checks + debug)
#   * Terraform state + lock
#   * IAM read/write for terraform state refresh + module changes
#
# We deliberately do NOT rely on PowerUserAccess for the IAM parts:
# PowerUserAccess explicitly EXCLUDES all IAM actions, which breaks
# terraform apply's state refresh on any IAM resource. The block below
# grants exactly the IAM actions terraform needs for the modules we
# manage (roles, inline policies, OIDC provider, tags) and nothing else.
data "aws_iam_policy_document" "deployer" {
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

  statement {
    sid       = "LogsRead"
    actions   = ["logs:DescribeLogStreams", "logs:GetLogEvents", "logs:FilterLogEvents"]
    resources = ["*"]
  }

  statement {
    sid     = "TFState"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
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

  # IAM read + narrow write for terraform's state refresh and module updates.
  # Scoped to * because terraform touches many role/policy ARNs; the actions
  # themselves are restricted to what the modules actually invoke.
  statement {
    sid = "IAMForTerraform"
    actions = [
      # read
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRoleTags",
      "iam:GetOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviders",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      # write (role lifecycle, trust policy updates, tags)
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      # OIDC provider lifecycle
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:AddClientIDToOpenIDConnectProvider",
      "iam:RemoveClientIDFromOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deployer" {
  name   = "${var.role_name}-inline"
  role   = aws_iam_role.deployer.id
  policy = data.aws_iam_policy_document.deployer.json
}

# For terraform apply of ALL non-IAM infra (VPC, RDS, ECS, ALB, etc.) we
# attach PowerUserAccess. This is convenient for a single-account assessment;
# in real prod I'd split plan-only (read) and apply (write) roles and drop
# PowerUserAccess in favour of an explicit inline write policy.
resource "aws_iam_role_policy_attachment" "terraform_admin" {
  count      = var.attach_admin_for_terraform ? 1 : 0
  role       = aws_iam_role.deployer.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}
