resource "aws_ses_domain_identity" "main" {
  domain = var.domain_name
}

resource "aws_ses_domain_dkim" "main" {
  domain = aws_ses_domain_identity.main.domain
}

resource "aws_ses_domain_mail_from" "main" {
  domain                 = aws_ses_domain_identity.main.domain
  mail_from_domain       = "mail.${var.domain_name}"
  behavior_on_mx_failure = "RejectMessage"
}

resource "aws_ses_receipt_rule_set" "main" {
  rule_set_name = "${var.project_name}-${var.environment}-rules"
}

resource "aws_ses_active_receipt_rule_set" "main" {
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
}

resource "aws_ses_receipt_rule" "inbound" {
  name          = "${var.project_name}-${var.environment}-inbound-rule"
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
  recipients    = [var.public_email]
  enabled       = true
  scan_enabled  = true

  s3_action {
    bucket_name       = var.bucket_name
    object_key_prefix = "staging/"
    position          = 1
  }

  lambda_action {
    function_arn    = var.inbound_lambda_arn
    invocation_type = "Event"
    position        = 2
  }

  depends_on = [aws_ses_active_receipt_rule_set.main, var.inbound_ses_permission]
}

resource "aws_ses_receipt_rule" "reply" {
  name          = "${var.project_name}-${var.environment}-reply-rule"
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
  recipients    = ["thread.${var.domain_name}"]
  enabled       = true
  scan_enabled  = true

  s3_action {
    bucket_name       = var.bucket_name
    object_key_prefix = "staging/"
    position          = 1
  }

  lambda_action {
    function_arn    = var.reply_lambda_arn
    invocation_type = "Event"
    position        = 2
  }

  depends_on = [aws_ses_active_receipt_rule_set.main, var.reply_ses_permission]
}

resource "aws_s3_bucket_policy" "ses_write" {
  bucket = var.bucket_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSESPuts"
        Effect = "Allow"
        Principal = {
          Service = "ses.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "arn:aws:s3:::${var.bucket_name}/staging/*"
      }
    ]
  })
}
