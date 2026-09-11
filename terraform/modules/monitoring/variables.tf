variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "alert_emails" {
  type    = list(string)
  default = []
}

variable "alb_arn_suffix" {
  type = string
}

variable "target_group_arn_suffix" {
  type = string
}

variable "ecs_cluster_name" {
  type = string
}

variable "ecs_service_name" {
  type = string
}

variable "rds_instance_id" {
  type = string
}

variable "rds_conn_threshold" {
  type    = number
  default = 80
}

variable "tags" {
  type    = map(string)
  default = {}
}
