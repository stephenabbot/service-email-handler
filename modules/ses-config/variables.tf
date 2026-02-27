variable "domain_name" {
  description = "Domain name"
  type        = string
}

variable "public_email" {
  description = "Public email address"
  type        = string
}

variable "bucket_name" {
  description = "S3 bucket name"
  type        = string
}

variable "inbound_lambda_arn" {
  description = "Inbound handler Lambda ARN"
  type        = string
}

variable "reply_lambda_arn" {
  description = "Reply handler Lambda ARN"
  type        = string
}

variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment"
  type        = string
}

variable "inbound_ses_permission" {
  description = "Inbound Lambda SES permission resource"
  type        = any
}

variable "reply_ses_permission" {
  description = "Reply Lambda SES permission resource"
  type        = any
}
