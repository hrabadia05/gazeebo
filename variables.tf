# ==========================================
# GAZEEBO INFRASTRUCTURE VARIABLES
# ==========================================

variable "aws_region" {
  description = "The AWS region where all infrastructure resources will be deployed."
  type        = string
  default     = "us-west-1"
}

variable "app_name" {
  description = "Application name prefix used for naming resources."
  type        = string
  default     = "gazeebo"
}

variable "environment" {
  description = "Deployment environment (e.g., dev, staging, prod)."
  type        = string
  default     = "prod"
}

variable "dynamodb_table_name" {
  description = "Name of the DynamoDB table used for metadata storage and state locking."
  type        = string
  default     = "GazeeboPortalData"
}

variable "s3_prefix" {
  description = "Prefix folder within the private S3 bucket where photo assets are stored."
  type        = string
  default     = "photos/"
}

variable "presigned_url_expiration_read" {
  description = "Expiration time in seconds for GET pre-signed view URLs."
  type        = number
  default     = 3600 # 1 hour
}

variable "presigned_url_expiration_upload" {
  description = "Expiration time in seconds for POST pre-signed upload URLs."
  type        = number
  default     = 300 # 5 minutes
}
