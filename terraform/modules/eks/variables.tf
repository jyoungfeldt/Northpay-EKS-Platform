variable "cluster_name" { type = string }
variable "cluster_version" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "environment" { type = string }
variable "aws_account_id" { type = string }
variable "aws_region" { type = string }
