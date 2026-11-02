variable "name" {
  type = string
}

variable "cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "availability_zones" {
  type = list(string)
}

variable "environment" {
  type = string
}

variable "cluster_name" {
  type = string
}
