# Planned Changes

Based on z_refactor.md requirements. All changes listed below will be made in a single pass.

## 1. SES DMARC Fix

**File:** `modules/ses-config/main.tf`
- Add `behavior_on_mx_failure = "RejectMessage"` to `aws_ses_domain_mail_from.main`
- Prevents silent fallback to amazonses.com MAIL FROM on transient MX failures

## 2. New Module: SQS Queues

**New files:**
- `modules/sqs-queues/main.tf`
- `modules/sqs-queues/variables.tf`
- `modules/sqs-queues/outputs.tf`

**Resources (6 queues):**
| Queue | Type | Visibility Timeout | Retention | maxReceiveCount |
|-------|------|-------------------|-----------|-----------------|
| `{project}-{env}-ack-sender` | Standard | 180s | 1 day | 5 → DLQ |
| `{project}-{env}-ack-sender-dlq` | Standard | 30s | 7 days | — |
| `{project}-{env}-forward-sender` | Standard | 180s | 1 day | 5 → DLQ |
| `{project}-{env}-forward-sender-dlq` | Standard | 30s | 7 days | — |
| `{project}-{env}-reply-sender` | Standard | 180s | 1 day | 5 → DLQ |
| `{project}-{env}-reply-sender-dlq` | Standard | 30s | 7 days | — |

## 3. New Sender Lambda Functions

**New files (3 Lambdas, each with handler + requirements):**
- `lambda/ack-sender/handler.py` + `requirements.txt`
- `lambda/forward-sender/handler.py` + `requirements.txt`
- `lambda/reply-sender/handler.py` + `requirements.txt`

**Shared pattern for all 3 sender Lambdas:**
- Triggered by SQS event source mapping (batch size 1)
- Parse message body as JSON for email parameters
- Exponential backoff retry loop: immediate, 5s, 30s, 120s (4 attempts)
- Retryable errors: `MailFromDomainNotVerified`, `Throttling`, `ServiceUnavailable`
- On final failure: raise exception (SQS handles redelivery → DLQ)
- Structured logging with mypylogger (attempt number, error codes, recipient)

**Per-Lambda specifics:**
| Lambda | SES Source | Destination | Extra fields |
|--------|-----------|-------------|--------------|
| ack-sender | PUBLIC_EMAIL | message.recipient | — |
| forward-sender | PUBLIC_EMAIL | PRIVATE_EMAIL | ReplyToAddresses from message |
| reply-sender | PUBLIC_EMAIL | message.recipient | — |

## 4. Terraform: Lambda Functions Module Updates

**File:** `modules/lambda-functions/main.tf`

**Add for each sender Lambda (ack, forward, reply):**
- IAM role + policy (CloudWatch Logs, SES SendEmail/SendRawEmail, SNS Publish, SQS ReceiveMessage/DeleteMessage/GetQueueAttributes)
- Lambda function (Python 3.12, 120s timeout, 256MB)
- CloudWatch log group (365-day retention)
- SQS event source mapping (batch size 1)

**File:** `modules/lambda-functions/variables.tf`
- Add: `ack_queue_arn`, `forward_queue_arn`, `reply_queue_arn`

**File:** `modules/lambda-functions/outputs.tf`
- Add outputs for 3 sender Lambda names

**Modify existing IAM policies:**
- inbound-handler: add `sqs:SendMessage` for ack + forward queue ARNs
- reply-handler: add `sqs:SendMessage` for reply queue ARN, add `dynamodb:GetItem` (already present)

**Modify existing Lambda env vars:**
- inbound-handler: add `ACK_QUEUE_URL`, `FORWARD_QUEUE_URL`
- reply-handler: add `REPLY_QUEUE_URL`

## 5. Modify Inbound Handler

**File:** `lambda/inbound-handler/handler.py`

**Changes:**
1. Add `sqs` boto3 client and `ACK_QUEUE_URL` / `FORWARD_QUEUE_URL` env vars
2. Add `hashlib` import for LinkedIn conversation ID hashing
3. Replace `email_to_conversation_id()` with version that handles LinkedIn:
   - If sender domain is `bounce.linkedin.com`: extract display name from From header, slugify, append 6-char SHA256 hash of raw email address → `jane-smith-linkedin-a3f8c1`
   - Otherwise: existing `email.replace('@', '-at-')` behavior
4. Add `extract_display_name(msg)` helper to parse RFC5322 From header display name
5. Replace `send_acknowledgement()`: enqueue JSON to ack-sender SQS instead of direct SES call
6. Replace `forward_to_private()`: enqueue JSON to forward-sender SQS instead of direct SES call
7. `store_conversation()`: add `displayName` attribute when available
8. Enhanced logging: add `body_preview` (500 chars), `conversation_id` to all log events

## 6. Modify Reply Handler

**File:** `lambda/reply-handler/handler.py`

**Changes:**
1. Add `sqs` boto3 client and `REPLY_QUEUE_URL` env var
2. Replace `conversation_id_to_email()` with DynamoDB `GetItem` lookup:
   - Query by `conversationId` key → retrieve `senderEmail`
   - If not found: log error, publish SNS alert, return
3. Replace direct `ses.send_email()` with `sqs.send_message()` to reply-sender queue
4. Enhanced logging: add `subject`, `body_preview` (500 chars) to log events

## 7. CloudWatch Alarms Module Updates

**File:** `modules/cloudwatch-alarms/main.tf`

**Add 6 new alarms:**
- 3 DLQ depth alarms: `ApproximateNumberOfMessagesVisible >= 1` on each DLQ (1-min period, 1 eval period)
- 3 sender Lambda error alarms: `Errors >= 1` on each sender Lambda (60s period, 1 eval period)

**File:** `modules/cloudwatch-alarms/variables.tf`
- Add: `ack_sender_lambda_name`, `forward_sender_lambda_name`, `reply_sender_lambda_name`
- Add: `ack_dlq_name`, `forward_dlq_name`, `reply_dlq_name`

## 8. Root main.tf Wiring

**File:** `main.tf`

- Add `module "sqs_queues"` block
- Pass queue ARNs from sqs module → lambda_functions module
- Pass sender Lambda names + DLQ names from lambda_functions → cloudwatch_alarms module

## 9. SQS Message Schemas

**ack-sender queue message:**
```json
{
  "recipient": "sender@example.com",
  "subject": "Thank you for reaching out",
  "body": "<auto-acknowledgement text>"
}
```

**forward-sender queue message:**
```json
{
  "recipient": "abbotnh@yahoo.com",
  "subject": "Fwd: Original Subject",
  "body": "<body + metadata footer>",
  "reply_to": "conv-id@thread.denverbytes.com"
}
```

**reply-sender queue message:**
```json
{
  "recipient": "original-sender@example.com",
  "subject": "Re: Original Subject",
  "body": "<cleaned reply body>"
}
```

## Files Created (New)
- `modules/sqs-queues/main.tf`
- `modules/sqs-queues/variables.tf`
- `modules/sqs-queues/outputs.tf`
- `lambda/ack-sender/handler.py`
- `lambda/ack-sender/requirements.txt`
- `lambda/forward-sender/handler.py`
- `lambda/forward-sender/requirements.txt`
- `lambda/reply-sender/handler.py`
- `lambda/reply-sender/requirements.txt`

## Files Modified
- `modules/ses-config/main.tf`
- `modules/lambda-functions/main.tf`
- `modules/lambda-functions/variables.tf`
- `modules/lambda-functions/outputs.tf`
- `modules/cloudwatch-alarms/main.tf`
- `modules/cloudwatch-alarms/variables.tf`
- `lambda/inbound-handler/handler.py`
- `lambda/reply-handler/handler.py`
- `main.tf`

## Files NOT Modified
- `modules/dynamodb-tables/main.tf` — `displayName` is a non-key attribute, no schema change needed
- `modules/s3-buckets/*` — no changes
- `modules/route53-records/*` — no changes
- `lambda/attachment-extractor/*` — no changes
- `terraform.tfvars` — no changes
- `variables.tf` — no changes
