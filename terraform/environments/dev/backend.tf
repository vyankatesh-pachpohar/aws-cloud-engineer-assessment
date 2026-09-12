terraform {
  backend "s3" {
    # These values are supplied via `terraform init -backend-config=` OR
    # by hard-coding after you've bootstrapped (see terraform/backend/).
    # bucket         = "order-api-tfstate-<account-id>"
    # key            = "dev/terraform.tfstate"
    # region         = "ap-south-1"
    # dynamodb_table = "order-api-tf-locks"
    # encrypt        = true
  }
}
