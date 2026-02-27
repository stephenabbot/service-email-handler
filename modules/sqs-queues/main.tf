locals {
  queue_names = ["ack-sender", "forward-sender", "reply-sender"]
}

resource "aws_sqs_queue" "sender_dlq" {
  for_each = toset(local.queue_names)

  name                      = "${var.project_name}-${var.environment}-${each.key}-dlq"
  message_retention_seconds = 604800 # 7 days
  visibility_timeout_seconds = 30
}

resource "aws_sqs_queue" "sender" {
  for_each = toset(local.queue_names)

  name                      = "${var.project_name}-${var.environment}-${each.key}"
  message_retention_seconds = 86400 # 1 day
  visibility_timeout_seconds = 180

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.sender_dlq[each.key].arn
    maxReceiveCount     = 5
  })
}
