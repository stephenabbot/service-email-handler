variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "project_name" {
  description = "Project name from git repository"
  type        = string
}

variable "environment" {
  description = "Environment (prd, stg, tst, dev)"
  type        = string
}

variable "public_email" {
  description = "Public email address for receiving mail"
  type        = string
}

variable "private_email" {
  description = "Private email address for forwarding"
  type        = string
}

variable "domain_name" {
  description = "Domain name for email handling"
  type        = string
}

variable "alert_email" {
  description = "Email address for CloudWatch alarm notifications"
  type        = string
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
}
