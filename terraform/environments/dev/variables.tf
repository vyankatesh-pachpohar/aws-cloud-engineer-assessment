variable "project" {
  type    = string
  default = "order-api"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "owner" {
  type    = string
  default = "devops"
}

variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "container_image_tag" {
  type        = string
  default     = "bootstrap"
  description = "Overridden by CI/CD. On first apply, uses the placeholder 'bootstrap' image."
}

variable "alert_emails" {
  type    = list(string)
  default = []
}

variable "github_org" {
  type = string
}

variable "github_repo" {
  type = string
}

variable "tf_state_bucket" {
  type = string
}

variable "tf_lock_table" {
  type    = string
  default = "order-api-tf-locks"
}

variable "acm_certificate_arn" {
  type    = string
  default = ""
}
