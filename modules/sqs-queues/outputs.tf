output "ack_queue_arn" {
  description = "Ack sender queue ARN"
  value       = aws_sqs_queue.sender["ack-sender"].arn
}

output "ack_queue_url" {
  description = "Ack sender queue URL"
  value       = aws_sqs_queue.sender["ack-sender"].url
}

output "forward_queue_arn" {
  description = "Forward sender queue ARN"
  value       = aws_sqs_queue.sender["forward-sender"].arn
}

output "forward_queue_url" {
  description = "Forward sender queue URL"
  value       = aws_sqs_queue.sender["forward-sender"].url
}

output "reply_queue_arn" {
  description = "Reply sender queue ARN"
  value       = aws_sqs_queue.sender["reply-sender"].arn
}

output "reply_queue_url" {
  description = "Reply sender queue URL"
  value       = aws_sqs_queue.sender["reply-sender"].url
}

output "ack_dlq_name" {
  description = "Ack sender DLQ name"
  value       = aws_sqs_queue.sender_dlq["ack-sender"].name
}

output "forward_dlq_name" {
  description = "Forward sender DLQ name"
  value       = aws_sqs_queue.sender_dlq["forward-sender"].name
}

output "reply_dlq_name" {
  description = "Reply sender DLQ name"
  value       = aws_sqs_queue.sender_dlq["reply-sender"].name
}
