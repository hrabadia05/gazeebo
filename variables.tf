variable "aws_region" {
  description = "The AWS region to deploy resources into"
  type        = string
  default     = "us-west-1"
}

variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "gazeebo-portal"
}
