#!/usr/bin/env bash
# Tear everything down. Runs after emptying buckets/ECR to avoid destroy errors.
set -euo pipefail

cd "$(dirname "$0")/../terraform/environments/dev"

REPO="$(terraform output -raw ecr_repository_url 2>/dev/null | awk -F/ '{print $NF}' || true)"
LOGS_BUCKET="$(terraform output -json 2>/dev/null | jq -r '..|.value?|strings' | grep -m1 -- '-logs-' || true)"

if [[ -n "$REPO" ]]; then
  echo "Deleting all images in ECR $REPO"
  IMGS="$(aws ecr list-images --repository-name "$REPO" --query 'imageIds' --output json 2>/dev/null || echo '[]')"
  [[ "$IMGS" != "[]" && -n "$IMGS" ]] && aws ecr batch-delete-image --repository-name "$REPO" --image-ids "$IMGS" >/dev/null || true
fi

if [[ -n "$LOGS_BUCKET" ]]; then
  echo "Emptying S3 bucket $LOGS_BUCKET"
  aws s3 rm "s3://$LOGS_BUCKET" --recursive >/dev/null || true
fi

terraform destroy -auto-approve
echo "Done. Remember: bootstrap state bucket in terraform/backend/ is separate."
