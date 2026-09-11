#!/usr/bin/env bash
# Deploy from your laptop (equivalent of what GitHub Actions does).
set -euo pipefail

REGION="${AWS_REGION:-ap-south-1}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REPO="${ECR_REPO_NAME:-order-api-dev}"
TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null || date +%s)}"

REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
IMAGE="$REGISTRY/$REPO:$TAG"

echo "Logging in to ECR..."
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

echo "Building + pushing $IMAGE"
docker buildx build --platform linux/amd64 -f docker/Dockerfile -t "$IMAGE" --push .

echo "Applying Terraform with new image tag..."
cd terraform/environments/dev
terraform apply -auto-approve -var="container_image_tag=$TAG"

CLUSTER="$(terraform output -raw ecs_cluster)"
SERVICE="$(terraform output -raw ecs_service)"

echo "Registering new task definition + updating service..."
TASK_DEF_ARN="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].taskDefinition' --output text)"
aws ecs describe-task-definition --task-definition "$TASK_DEF_ARN" --query 'taskDefinition' > /tmp/td.json
jq --arg IMG "$IMAGE" '.containerDefinitions[0].image = $IMG
  | del(.taskDefinitionArn,.revision,.status,.requiresAttributes,.compatibilities,.registeredAt,.registeredBy)' \
  /tmp/td.json > /tmp/td-new.json
NEW_ARN="$(aws ecs register-task-definition --cli-input-json file:///tmp/td-new.json --query 'taskDefinition.taskDefinitionArn' --output text)"
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --task-definition "$NEW_ARN" --force-new-deployment >/dev/null
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"

URL="http://$(terraform output -raw alb_dns_name)"
echo "Smoke-testing $URL/health"
curl -sS "$URL/health" | jq
