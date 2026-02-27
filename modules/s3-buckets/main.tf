resource "aws_s3_bucket" "email_storage" {
  bucket        = var.bucket_name
  force_destroy = true
}

locals {
  bucket_id = aws_s3_bucket.email_storage.id
}

resource "aws_s3_bucket_public_access_block" "email_storage" {
  bucket = local.bucket_id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "email_storage" {
  bucket = local.bucket_id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "email_storage" {
  bucket = local.bucket_id

  rule {
    id     = "delete-old-deployments"
    status = "Enabled"

    filter {
      prefix = "deployments/"
    }

    expiration {
      days = 30
    }
  }
}

resource "aws_s3_bucket_notification" "attachment_extraction" {
  bucket = local.bucket_id

  lambda_function {
    lambda_function_arn = var.extractor_lambda_arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "attachments/"
    filter_suffix       = ".pdf"
  }

  lambda_function {
    lambda_function_arn = var.extractor_lambda_arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "attachments/"
    filter_suffix       = ".docx"
  }

  depends_on = [var.extractor_lambda_permission]
}
