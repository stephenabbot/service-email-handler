output "inbound_handler_arn" {
  description = "Inbound handler Lambda ARN"
  value       = aws_lambda_function.inbound_handler.arn
}

output "inbound_handler_name" {
  description = "Inbound handler Lambda name"
  value       = aws_lambda_function.inbound_handler.function_name
}

output "reply_handler_arn" {
  description = "Reply handler Lambda ARN"
  value       = aws_lambda_function.reply_handler.arn
}

output "reply_handler_name" {
  description = "Reply handler Lambda name"
  value       = aws_lambda_function.reply_handler.function_name
}

output "extractor_handler_arn" {
  description = "Attachment extractor Lambda ARN"
  value       = aws_lambda_function.extractor_handler.arn
}

output "extractor_handler_name" {
  description = "Attachment extractor Lambda name"
  value       = aws_lambda_function.extractor_handler.function_name
}

output "extractor_lambda_permission" {
  description = "Extractor Lambda S3 permission resource"
  value       = aws_lambda_permission.extractor_s3
}

output "inbound_ses_permission" {
  description = "Inbound Lambda SES permission resource"
  value       = aws_lambda_permission.inbound_ses
}

output "reply_ses_permission" {
  description = "Reply Lambda SES permission resource"
  value       = aws_lambda_permission.reply_ses
}

output "ack_sender_name" {
  description = "Ack sender Lambda name"
  value       = aws_lambda_function.ack_sender.function_name
}

output "forward_sender_name" {
  description = "Forward sender Lambda name"
  value       = aws_lambda_function.forward_sender.function_name
}

output "reply_sender_name" {
  description = "Reply sender Lambda name"
  value       = aws_lambda_function.reply_sender.function_name
}
