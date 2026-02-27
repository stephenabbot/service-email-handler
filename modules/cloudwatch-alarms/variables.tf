variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment"
  type        = string
}

variable "alert_email" {
  description = "Email address for alerts"
  type        = string
}

variable "inbound_lambda_name" {
  description = "Inbound handler Lambda name"
  type        = string
}

variable "reply_lambda_name" {
  description = "Reply handler Lambda name"
  type        = string
}

variable "extractor_lambda_name" {
  description = "Attachment extractor Lambda name"
  type        = string
}

variable "ack_sender_lambda_name" {
  description = "Ack sender Lambda name"
  type        = string
}

variable "forward_sender_lambda_name" {
  description = "Forward sender Lambda name"
  type        = string
}

variable "reply_sender_lambda_name" {
  description = "Reply sender Lambda name"
  type        = string
}

variable "ack_dlq_name" {
  description = "Ack sender DLQ name"
  type        = string
}

variable "forward_dlq_name" {
  description = "Forward sender DLQ name"
  type        = string
}

variable "reply_dlq_name" {
  description = "Reply sender DLQ name"
  type        = string
}
