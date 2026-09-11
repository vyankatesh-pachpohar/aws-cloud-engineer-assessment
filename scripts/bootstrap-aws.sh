#!/usr/bin/env bash
# Bootstrap the Terraform state bucket + lock table (one-time per AWS account).
set -euo pipefail

REGION="${AWS_REGION:-ap-south-1}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${TF_STATE_BUCKET:-order-api-tfstate-${ACCOUNT}}"

echo "Region:  $REGION"
echo "Account: $ACCOUNT"
echo "Bucket:  $BUCKET"

cd "$(dirname "$0")/../terraform/backend"
terraform init -input=false
terraform apply -auto-approve -input=false \
  -var="state_bucket=$BUCKET" \
  -var="region=$REGION"

echo
echo "Set these repository variables in GitHub Actions:"
echo "  TF_STATE_BUCKET = $BUCKET"
echo "  TF_LOCK_TABLE   = order-api-tf-locks"
echo "  AWS_REGION      = $REGION"
