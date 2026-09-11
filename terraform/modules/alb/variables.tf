variable "name"                 { type = string }
variable "vpc_id"               { type = string }
variable "public_subnet_ids"    { type = list(string) }
variable "target_port"          { type = number  default = 8000 }
variable "health_check_path"    { type = string  default = "/health" }
variable "certificate_arn"      { type = string  default = "" description = "ACM cert ARN; empty = HTTP only" }
variable "access_logs_bucket"   { type = string  default = "" }
variable "deletion_protection"  { type = bool    default = false }
variable "tags"                 { type = map(string) default = {} }
