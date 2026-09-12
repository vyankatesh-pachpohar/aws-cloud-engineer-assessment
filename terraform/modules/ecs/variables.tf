variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "alb_sg_id" {
  type = string
}

variable "target_group_arn" {
  type = string
}

variable "alb_arn_suffix" {
  type = string
}

variable "target_group_arn_suffix" {
  type = string
}

variable "container_image" {
  type        = string
  description = "Full ECR image URI:tag"
}

variable "container_port" {
  type    = number
  default = 8000
}

variable "task_cpu" {
  type    = number
  default = 512
}

variable "task_memory" {
  type    = number
  default = 1024
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "min_capacity" {
  type    = number
  default = 2
}

variable "max_capacity" {
  type    = number
  default = 10
}

variable "min_on_demand" {
  type        = number
  default     = 2
  description = "Baseline on-demand tasks; rest can be Spot"
}

variable "requests_per_target" {
  type    = number
  default = 200
}

variable "environment" {
  type    = map(string)
  default = {}
}

variable "secrets" {
  type        = map(string)
  default     = {}
  description = "map(env-name => secret ARN)"
}

variable "secret_arns" {
  type        = list(string)
  default     = []
  description = "ARNs the exec role may read"
}

variable "task_role_policy_arns" {
  type    = list(string)
  default = []
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "enable_exec" {
  type    = bool
  default = false
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "container_command" {
  type        = list(string)
  default     = null
  description = "Optional command override for the container. Used by the bootstrap image; leave null for the real app."
}
