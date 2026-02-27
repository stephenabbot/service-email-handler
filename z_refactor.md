service-email-handler: Architecture & Functional Requirements
Project: Pattern B SQS Retry + LinkedIn Conversation ID + Enhanced Logging
Date: 2026-02-25
Repository: github.com/stephenabbot/service-email-handler

1. Executive Summary
Three related improvements to the AWS-based personal email handler:

Pattern B (SQS-based retry) — Route all SES sends through dedicated SQS queues with exponential backoff retry

LinkedIn conversation ID readability — Extract display names from opaque sender addresses and create human-readable conversation IDs

Enhanced logging — Include sender, subject, and body preview in all log events using mypylogger

Impact: Zero-cost when idle, resilient to transient SES failures, better observability, readable LinkedIn conversation folders.

1. Current State
2.1 Architecture
3 Lambda functions:

inbound-handler: spam check → auto-ack (first contact) → forward to private mailbox → DynamoDB update → S3 archive

reply-handler: decode sender from thread address → clean reply body → DynamoDB metadata update → send reply → archive

attachment-extractor: PDF/DOCX text extraction on S3 ObjectCreated events

All SES sends are direct/synchronous — no retry mechanism

SES custom MAIL FROM uses mail.denverbytes.com

behavior_on_mx_failure defaults to UseDefaultValue — silent fallback to amazonses.com breaks DMARC alignment without error

2.2 Known Issues
DMARC misalignment — One Outlook quarantine traced to transient MX failure causing SES to silently use amazonses.com

Opaque LinkedIn conversation IDs — <s-2kfvhrt4jg...@bounce.linkedin.com> becomes unreadable S3 prefix

Reply handler string reversal — conversation_id.replace('-at-', '@') breaks when IDs become slugs

Logs lack context — No sender/subject/body in log events

1. Target Architecture
3.1 New Components
SQS Queues (3 main + 3 DLQs):

service-email-handler-prd-ack-sender + DLQ

service-email-handler-prd-forward-sender + DLQ

service-email-handler-prd-reply-sender + DLQ

All queues: Standard (not FIFO), 180s visibility timeout, 1-day retention, maxReceiveCount=5, DLQ 7-day retention.

New Lambda Functions (3):

service-email-handler-prd-ack-sender

service-email-handler-prd-forward-sender

service-email-handler-prd-reply-sender

Each: Python 3.12, 120s timeout, 256MB memory, SQS event source, reads queue, retries SES send with exponential backoff, logs to CloudWatch, notifies SNS on final failure.

CloudWatch Alarms (6 new):

3 DLQ depth alarms (≥1 message triggers alert to existing SNS topic)

3 Lambda Errors alarms (>0 errors in 5min window)

3.2 Modified Components
SES Configuration:

Set behavior_on_mx_failure = "RejectMessage" in aws_ses_domain_mail_from

inbound-handler Lambda:

Replace direct ses.send_email with sqs.send_message for ack and forward operations

Add display-name extraction from From: header

Build human-readable conversation IDs for bounce.linkedin.com domains using display name + 6-char hash suffix

Add sender_email, subject, body_preview (500 chars) to all log events via mypylogger extra dict

reply-handler Lambda:

Replace direct ses.send_email with sqs.send_message

Replace conversation_id_to_email() string reversal with DynamoDB GetItem lookup of senderEmail by conversationId key

Add sender/subject/body logging

DynamoDB schema addition:

Add displayName attribute (string, optional) to conversation items

1. Functional Requirements
FR-1: SES Failure Visibility
Given SES custom MAIL FROM MX lookup fails

When Lambda attempts to send email

Then SES raises MailFromDomainNotVerified error (not silent fallback)

FR-2: Exponential Backoff Retry
Given SES send fails with retryable error (e.g., MailFromDomainNotVerified, throttling)

When sender Lambda processes SQS message

Then retry schedule: immediate, 5s, 30s, 120s (4 attempts total)

And each retry logs attempt number, error code, and context

FR-3: DLQ on Final Failure
Given SES send fails after 4 in-Lambda retries

When Lambda returns error

Then SQS increments receive count

And after maxReceiveCount=5, message moves to DLQ

And SNS publishes alert with recipient, error code, attempt count

FR-4: DLQ Depth Alarm
Given any message lands in any DLQ

When CloudWatch evaluates ApproximateNumberOfMessagesVisible ≥ 1

Then alarm triggers within 1 minute

And SNS sends email to private_email address

FR-5: LinkedIn Conversation ID
Given inbound email from bounce.linkedin.com domain

When From: header contains display name (e.g., "Jane Smith <s-2kfv...@bounce.linkedin.com>")

Then conversation ID = jane-smith-linkedin-a3f8c1 (slug + 6-char SHA256 hash of raw email)

And S3 prefix = conversations/jane-smith-linkedin-a3f8c1/

And DynamoDB item conversationId = jane-smith-linkedin-a3f8c1

And DynamoDB item displayName = Jane Smith

And DynamoDB item senderEmail = full original address

FR-6: Non-LinkedIn Conversation ID (unchanged)
Given inbound email from non-opaque domain (e.g., <anoop@synchronycorp.com>)

When creating conversation ID

Then conversation ID = anoop-at-synchronycorp.com (existing behavior)

FR-7: Reply Handler Sender Lookup
Given reply to <jane-smith-linkedin-a3f8c1@thread.denverbytes.com>

When reply handler decodes conversation ID

Then query DynamoDB: GetItem(conversationId='jane-smith-linkedin-a3f8c1')

And retrieve senderEmail attribute

And enqueue reply send to reply-sender queue with original email address

FR-8: Enhanced Logging (all log events)
Given any Lambda processes an email

When logging via mypylogger

Then include in extra dict:

sender_email (or sender or recipient depending on context)

subject

body_preview (first 500 characters of plain text body)

conversation_id

attempt (for retries)

error_code (on failures)

Example:

python
logger.info("email_received", extra={
    "sender": sender_email,
    "subject": subject,
    "body_preview": body_text[:500],
    "conversation_id": conversation_id
})
FR-9: Zero Idle Cost
Given no emails are being sent

When system is idle

Then SQS queues incur $0 cost (no messages stored/processed)

And sender Lambdas incur $0 cost (no invocations)

And DLQ alarms and existing Lambda alarms use only native CloudWatch metrics (no custom metrics)

FR-10: Existing Behavior Preserved
Spam filtering logic unchanged

Auto-acknowledgement on first contact unchanged (just routed via SQS)

Forward to private mailbox unchanged (just routed via SQS)

DynamoDB conversation schema compatible (adds optional displayName field)

Attachment extraction unchanged

All existing CloudWatch alarms for inbound/reply/extractor Lambdas unchanged

1. Architecture Decisions
AD-1: Three Separate Queues
Decision: Use 3 dedicated SQS queues (ack-sender, forward-sender, reply-sender) instead of 1 shared queue.
Rationale: Separate queues simplify Lambda logic (no branching on message type), enable independent retry/DLQ policies per send type, and provide clear observability per operation.

AD-2: Dedicated Sender Lambdas
Decision: Create 3 new Lambda functions for sending, not reusing existing handlers.
Rationale: Keeps Lambda logic pure (single responsibility), avoids mixing inbound/reply concerns with retry logic, easier testing and monitoring.

AD-3: In-Lambda Retry Before SQS Retry
Decision: Implement exponential backoff retry (4 attempts) inside the Lambda, not via SQS DelaySeconds.
Rationale: SQS Standard queues don't support per-message delay; using visibility timeout for backoff would complicate message handling. In-Lambda retry is simpler, completes faster for transient failures, and still has SQS-level retry (maxReceiveCount=5) as a safety net.

AD-4: behavior_on_mx_failure = RejectMessage
Decision: Change SES config to reject sends on MX failure instead of silent fallback.
Rationale: Makes failures explicit and actionable; retry logic can handle the error; prevents DMARC-breaking sends.

AD-5: Display Name + Hash for LinkedIn IDs
Decision: Use display-name-linkedin-<6-char-hash> for LinkedIn conversation IDs.
Rationale: Human-readable, deterministic (same email always produces same ID), collision-resistant (hash ensures uniqueness), short enough for S3/DynamoDB keys.

AD-6: DynamoDB Lookup in Reply Handler
Decision: Replace string reversal with DynamoDB GetItem to resolve sender from conversation ID.
Rationale: Necessary for slug-based IDs where reversal doesn't work; more robust and explicit; minimal latency cost (single-item lookup).

AD-7: Log Context via mypylogger extra
Decision: Use mypylogger's extra dict for structured logging, not string formatting.
Rationale: Produces clean JSON logs; fields are queryable in CloudWatch Logs Insights; consistent with mypylogger best practices; no PII in message field.

1. Data Flow
6.1 Inbound Email → Ack Send
text
SES → inbound-handler → [spam check] → [parse display name] → [build conversation ID]
  → sqs.send_message(ack-sender queue, {recipient, subject, body, attempt=1})
  → ack-sender Lambda → [backoff retry loop] → ses.send_email → done
6.2 Inbound Email → Forward Send
text
inbound-handler → [after ack] → [build forward body with metadata footer]
  → sqs.send_message(forward-sender queue, {sender, subject, body, conversation_id, attempt=1})
  → forward-sender Lambda → [backoff retry loop] → ses.send_email (to private mailbox) → done
6.3 Reply Email → Reply Send
text
SES → reply-handler → [extract conversation ID from thread address]
  → dynamodb.get_item(conversationId) → retrieve senderEmail
  → [parse metadata commands] → [clean reply body]
  → sqs.send_message(reply-sender queue, {recipient=senderEmail, subject, body, attempt=1})
  → reply-sender Lambda → [backoff retry loop] → ses.send_email (to original sender) → done
6.4 Failure Path
text
sender Lambda → ses.send_email fails → retry (5s delay) → fails → retry (30s delay) → fails
  → retry (120s) → fails → Lambda returns error → SQS redelivers (up to 5 times)
  → maxReceiveCount exceeded → message to DLQ
  → CloudWatch alarm triggers → SNS email to private_email
2. Non-Functional Requirements
NFR-1: Latency
Successful email send (no retries): <2 seconds end-to-end from queue enqueue to SES completion

Failed send with full retry: <180 seconds (sum of backoff delays)

NFR-2: Cost
Idle cost: $0

Per-email cost (successful): ~$0.0001 (1 SQS send + 1 SQS receive + 1 Lambda invocation + SES send)

Failed email (DLQ): <$0.001 (multiple retries + SNS alert)

NFR-3: Observability
All operations logged with structured JSON (mypylogger)

DLQ messages include full context (recipient, error, attempts)

CloudWatch alarms trigger within 60 seconds of DLQ message arrival

No custom metrics required (use native SQS/Lambda metrics only)

NFR-4: Resilience
System tolerates transient SES failures up to ~3 minutes (4 retries with 120s max delay)

No data loss: emails that fail permanently land in DLQ with 7-day retention for manual review/redrive

NFR-5: Backward Compatibility
Existing conversation IDs unchanged (non-LinkedIn senders)

Existing DynamoDB items work without migration (displayName is optional)

Reply handler gracefully handles both old and new conversation ID formats

1. Testing Scenarios
TS-1: Normal Send Path
Send email to <stephen.abbot@denverbytes.com> from <test@example.com>

Verify ack queued and sent within 2s

Verify forward queued and sent to private mailbox within 2s

Verify conversation ID = test-at-example.com

Verify logs contain sender, subject, body_preview

TS-2: LinkedIn Sender
Send email with From: Jane Smith <s-2kfv...@bounce.linkedin.com>

Verify conversation ID matches pattern jane-smith-linkedin-<hash>

Verify S3 prefix = conversations/jane-smith-linkedin-<hash>/

Verify DynamoDB item has displayName = "Jane Smith" and senderEmail = "<s-2kfv...@bounce.linkedin.com>"

Reply via thread.denverbytes.com

Verify reply handler looks up senderEmail from DynamoDB

Verify reply sent to original LinkedIn address

TS-3: Transient SES Failure
Temporarily break mail.denverbytes.com MX record

Send email → verify ack-sender Lambda logs MailFromDomainNotVerified

Verify retry attempt 2 after 5s

Restore MX record

Verify retry succeeds

Verify no DLQ message

TS-4: Persistent SES Failure
Break MX record permanently

Send email → verify 4 in-Lambda retries logged

Verify Lambda returns error →
