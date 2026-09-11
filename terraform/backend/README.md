# Terraform backend bootstrap

Creates the S3 bucket and DynamoDB table that the environments use for remote
state and state locking. Run **once** per AWS account.

```bash
cd terraform/backend
terraform init
terraform apply \
  -var="state_bucket=order-api-tfstate-<your-account-id>" \
  -var="region=ap-south-1"
```

Then wire the outputs into `terraform/environments/*/backend.tf`.
