# Convenience targets. Requires: docker, terraform, awscli, jq
SHELL := /bin/bash
.DEFAULT_GOAL := help
ENV_DIR := terraform/environments/dev

help:
	@echo "Targets:"
	@echo "  make up            docker compose up (local)"
	@echo "  make down          docker compose down"
	@echo "  make test          run pytest"
	@echo "  make build         build docker image"
	@echo "  make tf-init       terraform init (dev)"
	@echo "  make tf-plan       terraform plan (dev)"
	@echo "  make tf-apply      terraform apply (dev)"
	@echo "  make tf-destroy    terraform destroy (dev)"
	@echo "  make health        curl /health via the ALB DNS output"

up:
	docker compose up --build

down:
	docker compose down -v

test:
	cd app && pip install -q -r requirements-dev.txt && pytest -q

build:
	docker build -f docker/Dockerfile -t order-api:local .

tf-init:
	cd $(ENV_DIR) && terraform init

tf-plan:
	cd $(ENV_DIR) && terraform plan

tf-apply:
	cd $(ENV_DIR) && terraform apply

tf-destroy:
	cd $(ENV_DIR) && terraform destroy

health:
	@URL="http://$$(cd $(ENV_DIR) && terraform output -raw alb_dns_name)/health"; \
	 echo "GET $$URL"; curl -sS "$$URL" | jq
