# terraform/backend/main.tf
# One-time bootstrap: create the S3 bucket + DynamoDB table that the main
# Terraform environments use for remote state and state locking.
# Run this from your local machine ONCE per AWS account.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
  # NOTE: local state on purpose — this stack creates the remote-state backend.
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Purpose   = "tf-remote-state-bootstrap"
    }
  }
}

variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "project" {
  type    = string
  default = "order-api"
}

variable "state_bucket" {
  type        = string
  description = "Globally-unique bucket name for TF state"
}

variable "lock_table" {
  type    = string
  default = "order-api-tf-locks"
}

# ---------- state bucket ----------
resource "aws_s3_bucket" "state" {
  bucket        = var.state_bucket
  force_destroy = false      # never let TF nuke state
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"       # every apply is a new version -> recoverable
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------- lock table ----------
resource "aws_dynamodb_table" "lock" {
  name         = var.lock_table
  billing_mode = "PAY_PER_REQUEST"     # cheap: only pay per lock op
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}

output "state_bucket" {
  value = aws_s3_bucket.state.id
}

output "lock_table" {
  value = aws_dynamodb_table.lock.name
}
