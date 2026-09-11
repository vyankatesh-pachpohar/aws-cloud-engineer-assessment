variable "role_name" {
  type = string
}

variable "github_org" {
  type = string
}

variable "github_repo" {
  type = string
}

variable "allowed_subjects" {
  type    = list(string)
  default = ["ref:refs/heads/main", "environment:dev", "environment:prod"]
}

variable "passable_role_arns" {
  type    = list(string)
  default = []
}

variable "tf_state_bucket" {
  type = string
}

variable "tf_lock_table" {
  type = string
}

variable "create_provider" {
  type    = bool
  default = true
}

variable "attach_admin_for_terraform" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
