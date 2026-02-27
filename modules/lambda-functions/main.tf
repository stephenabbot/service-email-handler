locals {
  inbound_name        = "${var.project_name}-${var.environment}-inbound-handler"
  reply_name          = "${var.project_name}-${var.environment}-reply-handler"
  extractor_name      = "${var.project_name}-${var.environment}-attachment-extractor"
  ack_sender_name     = "${var.project_name}-${var.environment}-ack-sender"
  forward_sender_name = "${var.project_name}-${var.environment}-forward-sender"
  reply_sender_name   = "${var.project_name}-${var.environment}-reply-sender"
}

# IAM Role for Inbound Handler
resource "aws_iam_role" "inbound_handler" {
  name = "${local.inbound_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "inbound_handler" {
  name = "${local.inbound_name}-policy"
  role = aws_iam_role.inbound_handler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "arn:aws:s3:::${var.bucket_name}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query"
        ]
        Resource = [
          "arn:aws:dynamodb:*:*:table/${var.table_name}",
          "arn:aws:dynamodb:*:*:table/${var.table_name}/index/*"
        ]
      },
      {
        Effect = "Allow"
        Action = "sqs:SendMessage"
        Resource = [
          var.ack_queue_arn,
          var.forward_queue_arn
        ]
      },
      {
        Effect = "Allow"
        Action = "sns:Publish"
        Resource = var.sns_topic_arn
      },
      {
        Effect = "Allow"
        Action = "ssm:GetParameter"
        Resource = "arn:aws:ssm:*:*:parameter/service-email-handler/${var.environment}/spam-keywords-s3-key"
      }
    ]
  })
}

# Lambda Function for Inbound Handler
resource "aws_lambda_function" "inbound_handler" {
  function_name = local.inbound_name
  role          = aws_iam_role.inbound_handler.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.12"
  timeout       = 30
  memory_size   = 256

  filename         = "${path.root}/lambda/inbound-handler/deployment.zip"
  source_code_hash = filebase64sha256("${path.root}/lambda/inbound-handler/deployment.zip")

  environment {
    variables = {
      BUCKET_NAME             = var.bucket_name
      TABLE_NAME              = var.table_name
      PUBLIC_EMAIL            = var.public_email
      PRIVATE_EMAIL           = var.private_email
      DOMAIN_NAME             = var.domain_name
      SNS_TOPIC_ARN           = var.sns_topic_arn
      SPAM_KEYWORDS_SSM_PARAM = "/service-email-handler/${var.environment}/spam-keywords-s3-key"
      ACK_QUEUE_URL           = var.ack_queue_url
      FORWARD_QUEUE_URL       = var.forward_queue_url
    }
  }
}

resource "aws_cloudwatch_log_group" "inbound_handler" {
  name              = "/aws/lambda/${local.inbound_name}"
  retention_in_days = 365
  skip_destroy      = true
}

resource "aws_lambda_permission" "inbound_ses" {
  statement_id  = "AllowSESInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.inbound_handler.function_name
  principal     = "ses.amazonaws.com"
}

# IAM Role for Reply Handler
resource "aws_iam_role" "reply_handler" {
  name = "${local.reply_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "reply_handler" {
  name = "${local.reply_name}-policy"
  role = aws_iam_role.reply_handler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "arn:aws:s3:::${var.bucket_name}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:Query",
          "dynamodb:UpdateItem"
        ]
        Resource = [
          "arn:aws:dynamodb:*:*:table/${var.table_name}",
          "arn:aws:dynamodb:*:*:table/${var.table_name}/index/*"
        ]
      },
      {
        Effect = "Allow"
        Action = "sqs:SendMessage"
        Resource = var.reply_queue_arn
      },
      {
        Effect = "Allow"
        Action = "sns:Publish"
        Resource = var.sns_topic_arn
      }
    ]
  })
}

# Lambda Function for Reply Handler
resource "aws_lambda_function" "reply_handler" {
  function_name = local.reply_name
  role          = aws_iam_role.reply_handler.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.12"
  timeout       = 30
  memory_size   = 256

  filename         = "${path.root}/lambda/reply-handler/deployment.zip"
  source_code_hash = filebase64sha256("${path.root}/lambda/reply-handler/deployment.zip")

  environment {
    variables = {
      BUCKET_NAME    = var.bucket_name
      TABLE_NAME     = var.table_name
      PUBLIC_EMAIL   = var.public_email
      DOMAIN_NAME    = var.domain_name
      SNS_TOPIC_ARN  = var.sns_topic_arn
      REPLY_QUEUE_URL = var.reply_queue_url
    }
  }
}

resource "aws_cloudwatch_log_group" "reply_handler" {
  name              = "/aws/lambda/${local.reply_name}"
  retention_in_days = 365
  skip_destroy      = true
}

resource "aws_lambda_permission" "reply_ses" {
  statement_id  = "AllowSESInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reply_handler.function_name
  principal     = "ses.amazonaws.com"
}

# IAM Role for Attachment Extractor
resource "aws_iam_role" "extractor_handler" {
  name = "${local.extractor_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "extractor_handler" {
  name = "${local.extractor_name}-policy"
  role = aws_iam_role.extractor_handler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = "arn:aws:s3:::${var.bucket_name}/*"
      },
      {
        Effect = "Allow"
        Action = "dynamodb:UpdateItem"
        Resource = [
          "arn:aws:dynamodb:*:*:table/${var.table_name}",
          "arn:aws:dynamodb:*:*:table/${var.table_name}/index/*"
        ]
      }
    ]
  })
}

# Lambda Function for Attachment Extractor
resource "aws_lambda_function" "extractor_handler" {
  function_name = local.extractor_name
  role          = aws_iam_role.extractor_handler.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.12"
  timeout       = 30
  memory_size   = 256

  filename         = "${path.root}/lambda/attachment-extractor/deployment.zip"
  source_code_hash = filebase64sha256("${path.root}/lambda/attachment-extractor/deployment.zip")

  environment {
    variables = {
      BUCKET_NAME = var.bucket_name
      TABLE_NAME  = var.table_name
    }
  }
}

resource "aws_cloudwatch_log_group" "extractor_handler" {
  name              = "/aws/lambda/${local.extractor_name}"
  retention_in_days = 365
  skip_destroy      = true
}

resource "aws_lambda_permission" "extractor_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.extractor_handler.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = "arn:aws:s3:::${var.bucket_name}"
}

# Spam log group is created by Lambda code; manage it here for retention and lifecycle.
resource "aws_cloudwatch_log_group" "spam" {
  name              = "/email-handler/spam"
  retention_in_days = 365
  skip_destroy      = true
}

# ---------------------------------------------------------------------------
# Sender Lambdas (ack-sender, forward-sender, reply-sender)
# ---------------------------------------------------------------------------

# Shared IAM assume-role policy for sender Lambdas
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# --- Ack Sender ---

resource "aws_iam_role" "ack_sender" {
  name               = "${local.ack_sender_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "ack_sender" {
  name = "${local.ack_sender_name}-policy"
  role = aws_iam_role.ack_sender.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = var.ack_queue_arn
      },
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = var.sns_topic_arn
      }
    ]
  })
}

resource "aws_lambda_function" "ack_sender" {
  function_name = local.ack_sender_name
  role          = aws_iam_role.ack_sender.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.12"
  timeout       = 120
  memory_size   = 256

  filename         = "${path.root}/lambda/ack-sender/deployment.zip"
  source_code_hash = filebase64sha256("${path.root}/lambda/ack-sender/deployment.zip")

  environment {
    variables = {
      PUBLIC_EMAIL  = var.public_email
      SNS_TOPIC_ARN = var.sns_topic_arn
    }
  }
}

resource "aws_cloudwatch_log_group" "ack_sender" {
  name              = "/aws/lambda/${local.ack_sender_name}"
  retention_in_days = 365
  skip_destroy      = true
}

resource "aws_lambda_event_source_mapping" "ack_sender" {
  event_source_arn = var.ack_queue_arn
  function_name    = aws_lambda_function.ack_sender.arn
  batch_size       = 1
}

# --- Forward Sender ---

resource "aws_iam_role" "forward_sender" {
  name               = "${local.forward_sender_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "forward_sender" {
  name = "${local.forward_sender_name}-policy"
  role = aws_iam_role.forward_sender.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = var.forward_queue_arn
      },
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = var.sns_topic_arn
      }
    ]
  })
}

resource "aws_lambda_function" "forward_sender" {
  function_name = local.forward_sender_name
  role          = aws_iam_role.forward_sender.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.12"
  timeout       = 120
  memory_size   = 256

  filename         = "${path.root}/lambda/forward-sender/deployment.zip"
  source_code_hash = filebase64sha256("${path.root}/lambda/forward-sender/deployment.zip")

  environment {
    variables = {
      PUBLIC_EMAIL  = var.public_email
      SNS_TOPIC_ARN = var.sns_topic_arn
    }
  }
}

resource "aws_cloudwatch_log_group" "forward_sender" {
  name              = "/aws/lambda/${local.forward_sender_name}"
  retention_in_days = 365
  skip_destroy      = true
}

resource "aws_lambda_event_source_mapping" "forward_sender" {
  event_source_arn = var.forward_queue_arn
  function_name    = aws_lambda_function.forward_sender.arn
  batch_size       = 1
}

# --- Reply Sender ---

resource "aws_iam_role" "reply_sender" {
  name               = "${local.reply_sender_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "reply_sender" {
  name = "${local.reply_sender_name}-policy"
  role = aws_iam_role.reply_sender.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = var.reply_queue_arn
      },
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = var.sns_topic_arn
      }
    ]
  })
}

resource "aws_lambda_function" "reply_sender" {
  function_name = local.reply_sender_name
  role          = aws_iam_role.reply_sender.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.12"
  timeout       = 120
  memory_size   = 256

  filename         = "${path.root}/lambda/reply-sender/deployment.zip"
  source_code_hash = filebase64sha256("${path.root}/lambda/reply-sender/deployment.zip")

  environment {
    variables = {
      PUBLIC_EMAIL  = var.public_email
      SNS_TOPIC_ARN = var.sns_topic_arn
    }
  }
}

resource "aws_cloudwatch_log_group" "reply_sender" {
  name              = "/aws/lambda/${local.reply_sender_name}"
  retention_in_days = 365
  skip_destroy      = true
}

resource "aws_lambda_event_source_mapping" "reply_sender" {
  event_source_arn = var.reply_queue_arn
  function_name    = aws_lambda_function.reply_sender.arn
  batch_size       = 1
}
