output "s3_bucket_name" {
  description = "S3 bucket name for email storage"
  value       = module.s3_buckets.bucket_name
}

output "dynamodb_table_name" {
  description = "DynamoDB table name for conversation metadata"
  value       = module.dynamodb_tables.table_name
}

output "inbound_lambda_arn" {
  description = "Inbound handler Lambda ARN"
  value       = module.lambda_functions.inbound_handler_arn
}

output "reply_lambda_arn" {
  description = "Reply handler Lambda ARN"
  value       = module.lambda_functions.reply_handler_arn
}

output "extractor_lambda_arn" {
  description = "Attachment extractor Lambda ARN"
  value       = module.lambda_functions.extractor_handler_arn
}

output "sns_topic_arn" {
  description = "SNS topic ARN for alerts"
  value       = module.cloudwatch_alarms.sns_topic_arn
}
