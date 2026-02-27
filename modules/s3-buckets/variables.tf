variable "bucket_name" {
  description = "S3 bucket name"
  type        = string
}

variable "extractor_lambda_arn" {
  description = "Attachment extractor Lambda ARN"
  type        = string
  default     = ""
}

variable "extractor_lambda_permission" {
  description = "Extractor Lambda S3 permission resource"
  type        = any
  default     = null
}
