variable "domain_name" {
  description = "Domain name"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "dkim_tokens" {
  description = "DKIM tokens for SES domain verification"
  type        = list(string)
}

variable "alert_email" {
  description = "Email address for DMARC aggregate reports"
  type        = string
}
