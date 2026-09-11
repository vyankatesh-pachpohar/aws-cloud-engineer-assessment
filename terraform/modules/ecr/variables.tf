variable "name" {
  type = string
}

variable "force_delete" {
  type    = bool
  default = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
