variable "bucket_name" {
  type = string
}

variable "force_destroy" {
  type    = bool
  default = false
}

variable "log_expiration_days" {
  type    = number
  default = 90
}

variable "tags" {
  type    = map(string)
  default = {}
}
