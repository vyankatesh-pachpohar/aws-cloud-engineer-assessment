variable "name" {
  type = string
}

variable "cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

variable "nat_per_az" {
  type        = bool
  default     = false
  description = "true in prod: one NAT per AZ (HA); false in dev to save cost"
}

variable "enable_flow_logs" {
  type    = bool
  default = true
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}
