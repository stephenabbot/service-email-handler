terraform {
  required_version = ">= 1.0"
  
  backend "s3" {
    # Backend configuration loaded dynamically from SSM Parameter Store
    # See scripts/deploy.sh for implementation
  }
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  
  default_tags {
    tags = var.common_tags
  }
}

data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "hosted_zone_id" {
  name = "/static-website/infrastructure/${var.domain_name}/hosted-zone-id"
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  bucket_name = "${var.project_name}-${local.account_id}-${var.aws_region}"
  table_name = "${var.project_name}-${var.environment}-conversations"
}

module "s3_buckets" {
  source = "./modules/s3-buckets"
  
  bucket_name                  = local.bucket_name
  extractor_lambda_arn         = module.lambda_functions.extractor_handler_arn
  extractor_lambda_permission  = module.lambda_functions.extractor_lambda_permission
}

module "dynamodb_tables" {
  source = "./modules/dynamodb-tables"
  
  table_name = local.table_name
}

module "sqs_queues" {
  source = "./modules/sqs-queues"

  project_name = var.project_name
  environment  = var.environment
}

module "lambda_functions" {
  source = "./modules/lambda-functions"

  project_name       = var.project_name
  environment        = var.environment
  bucket_name        = module.s3_buckets.bucket_name
  table_name         = module.dynamodb_tables.table_name
  public_email       = var.public_email
  private_email      = var.private_email
  domain_name        = var.domain_name
  sns_topic_arn      = module.cloudwatch_alarms.sns_topic_arn
  ack_queue_arn      = module.sqs_queues.ack_queue_arn
  ack_queue_url      = module.sqs_queues.ack_queue_url
  forward_queue_arn  = module.sqs_queues.forward_queue_arn
  forward_queue_url  = module.sqs_queues.forward_queue_url
  reply_queue_arn    = module.sqs_queues.reply_queue_arn
  reply_queue_url    = module.sqs_queues.reply_queue_url
}

module "ses_config" {
  source = "./modules/ses-config"
  
  domain_name              = var.domain_name
  public_email             = var.public_email
  bucket_name              = module.s3_buckets.bucket_name
  inbound_lambda_arn       = module.lambda_functions.inbound_handler_arn
  reply_lambda_arn         = module.lambda_functions.reply_handler_arn
  project_name             = var.project_name
  environment              = var.environment
  inbound_ses_permission   = module.lambda_functions.inbound_ses_permission
  reply_ses_permission     = module.lambda_functions.reply_ses_permission
}

module "route53_records" {
  source = "./modules/route53-records"

  domain_name     = var.domain_name
  hosted_zone_id  = data.aws_ssm_parameter.hosted_zone_id.value
  aws_region      = var.aws_region
  dkim_tokens     = module.ses_config.dkim_tokens
  alert_email     = var.alert_email
}

module "cloudwatch_alarms" {
  source = "./modules/cloudwatch-alarms"

  project_name               = var.project_name
  environment                = var.environment
  alert_email                = var.alert_email
  inbound_lambda_name        = module.lambda_functions.inbound_handler_name
  reply_lambda_name          = module.lambda_functions.reply_handler_name
  extractor_lambda_name      = module.lambda_functions.extractor_handler_name
  ack_sender_lambda_name     = module.lambda_functions.ack_sender_name
  forward_sender_lambda_name = module.lambda_functions.forward_sender_name
  reply_sender_lambda_name   = module.lambda_functions.reply_sender_name
  ack_dlq_name               = module.sqs_queues.ack_dlq_name
  forward_dlq_name           = module.sqs_queues.forward_dlq_name
  reply_dlq_name             = module.sqs_queues.reply_dlq_name
}

resource "aws_ssm_parameter" "spam_keywords_s3_key" {
  name  = "/service-email-handler/${var.environment}/spam-keywords-s3-key"
  type  = "String"
  value = "spam-filter/keywords.txt"
}
