resource "aws_dynamodb_table" "conversations" {
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "conversationId"

  attribute {
    name = "conversationId"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  attribute {
    name = "senderEmail"
    type = "S"
  }

  attribute {
    name = "companyName"
    type = "S"
  }

  attribute {
    name = "emailDomain"
    type = "S"
  }

  attribute {
    name = "location"
    type = "S"
  }

  attribute {
    name = "salaryRange"
    type = "S"
  }

  attribute {
    name = "jobId"
    type = "S"
  }

  attribute {
    name = "type"
    type = "S"
  }

  attribute {
    name = "title"
    type = "S"
  }

  global_secondary_index {
    name            = "senderEmail-timestamp-index"
    hash_key        = "senderEmail"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "companyName-timestamp-index"
    hash_key        = "companyName"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "emailDomain-timestamp-index"
    hash_key        = "emailDomain"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "location-timestamp-index"
    hash_key        = "location"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "salaryRange-timestamp-index"
    hash_key        = "salaryRange"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "jobId-timestamp-index"
    hash_key        = "jobId"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "type-timestamp-index"
    hash_key        = "type"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "title-timestamp-index"
    hash_key        = "title"
    range_key       = "timestamp"
    projection_type = "ALL"
  }
}
