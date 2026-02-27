variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment"
  type        = string
}

variable "bucket_name" {
  description = "S3 bucket name"
  type        = string
}

variable "table_name" {
  description = "DynamoDB table name"
  type        = string
}

variable "public_email" {
  description = "Public email address"
  type        = string
}

variable "private_email" {
  description = "Private email address"
  type        = string
}

variable "domain_name" {
  description = "Domain name"
  type        = string
}

variable "sns_topic_arn" {
  description = "SNS topic ARN for alerts"
  type        = string
}

variable "ack_queue_arn" {
  description = "Ack sender SQS queue ARN"
  type        = string
}

variable "ack_queue_url" {
  description = "Ack sender SQS queue URL"
  type        = string
}

variable "forward_queue_arn" {
  description = "Forward sender SQS queue ARN"
  type        = string
}

variable "forward_queue_url" {
  description = "Forward sender SQS queue URL"
  type        = string
}

variable "reply_queue_arn" {
  description = "Reply sender SQS queue ARN"
  type        = string
}

variable "reply_queue_url" {
  description = "Reply sender SQS queue URL"
  type        = string
}
