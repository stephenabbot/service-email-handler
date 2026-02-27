# Implementation Notes

Design decisions made during implementation.

## Key Design Decisions

### Conversation Identity

`conversationId` is derived deterministically from the sender:

- **Standard senders**: `user@domain.com` → `user-at-domain.com`
- **LinkedIn senders** (`*@bounce.linkedin.com`): display name extracted from `From`
  header, slugified, suffixed with `-linkedin` →
  e.g. `Jane Smith <s-2kfv...@bounce.linkedin.com>` → `jane-smith-linkedin`

One DynamoDB item per sender, updated on every inbound email. `firstContactDate`
is protected with `if_not_exists` so follow-up emails never overwrite it.
`displayName` is stored for LinkedIn senders.

The reply handler resolves `conversationId` → `senderEmail` via DynamoDB `GetItem`
rather than string reversal. This supports both standard and LinkedIn-style IDs.

### DynamoDB Schema

Hash key only (`conversationId`) — no sort key. This is intentional:
metadata like `companyName`, `title`, and `firstContactDate` are
conversation-level attributes that must be updated in-place. A sort key
would require knowing the sort value to update a specific item, which
is not practical for this use case.

The 8 GSIs all use `timestamp` as their range key, allowing sorted
range queries per attribute (e.g. all contacts from company X ordered
by most recent).

### S3 Staging Pattern

SES writes raw emails to `staging/{messageId}`. Each Lambda reads from
staging, processes, then deletes. Objects that persist in `staging/`
indicate a processing failure and require forensic investigation. This
makes failure visible without any additional monitoring.

### Spam Keyword Cache

Keywords are cached at Lambda module level with a 5-minute TTL.
The indirection `SSM parameter → S3 key → keywords file` allows the
active file to be swapped without a Lambda redeployment (just update
the SSM parameter and the cache expires within 5 minutes).

### Custom MAIL FROM and DMARC Alignment

SES uses `mail.denverbytes.com` as the envelope sender domain (Return-Path).
This is a subdomain of `denverbytes.com`, so DMARC SPF alignment passes.
Combined with DKIM signing (`d=denverbytes.com`), DMARC passes via both
mechanisms and Outlook presents the sender as Verified.

`behavior_on_mx_failure = RejectMessage` — if the MX lookup for
`mail.denverbytes.com` fails transiently, SES rejects the send with
`MailFromDomainNotVerifiedException` rather than silently falling back to
`amazonses.com` as the MAIL FROM domain. Without this setting, a transient
MX failure causes SES to use `amazonses.com` for both envelope-from and
DKIM signing, which breaks DMARC alignment and results in quarantine at
receivers like Outlook. The sender Lambdas retry this error with
exponential backoff.

### SQS Retry Pattern

All outbound email sends are routed through dedicated SQS queues (ack-sender,
forward-sender, reply-sender) rather than calling SES directly from the
processing Lambdas. This provides:

- **Retry resilience**: exponential backoff (immediate, 5s, 30s, 120s) handles
  transient SES failures including `MailFromDomainNotVerifiedException`,
  throttling, and service unavailability
- **Decoupling**: the inbound/reply handler completes quickly (enqueue to SQS)
  regardless of SES send latency or failures
- **Visibility**: failed sends land in DLQs with 7-day retention for inspection
  and redrive, rather than being silently lost
- **Zero idle cost**: SQS queues and sender Lambdas incur no cost when no
  messages are in flight

Each queue has a paired DLQ with `maxReceiveCount=5`. After exhausting all
in-Lambda retries and all SQS redeliveries, the message moves to the DLQ
and a CloudWatch alarm fires.

### Sender Lambda Design

Three separate sender Lambdas (one per queue) rather than a single shared
sender. This keeps each Lambda's logic simple (no branching on message type),
enables independent retry/DLQ policies per send type, and provides clear
per-operation observability in CloudWatch.

All three share identical retry logic — the only difference is the SES
`send_email()` parameters (recipient, subject, body, optional `ReplyToAddresses`).

### Platform Flag

Lambda runs on x86_64. Podman on Apple Silicon defaults to arm64
containers. All Lambda builds use `--platform linux/amd64` to ensure
native extensions (`pcre2`, `lxml`) compile for the correct architecture.

### Error Handling Pattern

All Lambda error paths follow the same pattern:
1. `logger.error(event_name, extra={...})` — structured log with context
   (sender, subject, body_preview, conversation_id, attempt, error_code)
2. `sns.publish(...)` — alert for recoverable/expected errors
3. `raise` — only for the outer catch-all, lets Lambda report the
   unhandled exception and triggers the CloudWatch alarm

Sender Lambdas add a fourth dimension: after exhausting retries, they raise
the last error, causing SQS to redeliver (and eventually route to DLQ).

### Attachment Extraction

Attachments are extracted from the MIME email by the inbound handler and
written to `attachments/{conversationId}/{messageId}/{filename}`. The S3
bucket notification then triggers the attachment-extractor Lambda for any
`.pdf` or `.docx` files. The extracted text is stored at
`extracted-text/{conversationId}/{messageId}/{filename}.txt`.
