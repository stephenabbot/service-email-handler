# SES vs Lambda — Responsibility Boundary

## Overview

SES is the email transport layer. Lambda is the processing and logic layer.
Everything between "SES receives a raw email" and "SES sends something" is
handled exclusively in Lambda. All outbound sends are decoupled via SQS
queues with dedicated sender Lambdas.

## What SES Does

**Inbound (receiving email):**

- Accepts email via MX records pointed at SES inbound endpoints
- Performs spam, virus, SPF, and DKIM checks — results surfaced as verdicts
- Stores the raw `.eml` file in S3 under the `staging/` prefix
- Triggers the appropriate Lambda with a lightweight event containing:
  - Sender address, recipient address(es), message ID, timestamp
  - Spam/virus/SPF/DKIM verdicts

**Outbound (sending email):**

- Delivers email via `SendEmail` or `SendRawEmail` API
- Handles SMTP delivery, retries, and bounce processing
- Signs outbound mail with DKIM (`d=denverbytes.com`)
- Uses `mail.denverbytes.com` as the envelope sender (custom MAIL FROM)
- `behavior_on_mx_failure = RejectMessage` — rejects the send if the custom
  MAIL FROM MX lookup fails, rather than silently falling back to
  `amazonses.com` (which would break DMARC alignment)

## What SES Does NOT Do

- Parse MIME structure (multipart bodies, inline content vs attachments)
- Decode body encodings (base64, quoted-printable, charsets)
- Extract or interpret headers (`Subject`, `Reply-To`, `In-Reply-To`)
- Extract attachments
- Understand conversation threading or context
- Filter based on custom keyword patterns
- Enrich or transform email content

## What Lambda Does

Lambda contains all business logic. Six functions split into two categories:
processing Lambdas (triggered by SES/S3 events) and sender Lambdas
(triggered by SQS).

### Processing Lambdas

#### Inbound Handler

1. Reads raw `.eml` from `staging/{messageId}` in S3
2. Runs three-gate spam check:
   - Gate 1: SES verdict flags (`spamVerdict`, `virusVerdict`)
   - Gate 2: Recipient address matches configured public email
   - Gate 3: PCRE2 pattern matching on sender domain, subject, body
3. **If spam**: archives to `spam/{date}/{messageId}.eml`, logs to
   `/email-handler/spam`, deletes from staging
4. **If legitimate**:
   - Extracts display name from `From` header (for LinkedIn senders)
   - Builds conversation ID (standard: `user-at-domain.com`;
     LinkedIn: `jane-smith-linkedin`)
   - Enqueues auto-acknowledgement to `ack-queue` (first contact only,
     checked via DynamoDB)
   - Enqueues forward to `forward-queue` with `Reply-To` set to thread
     address and metadata footer appended
   - Archives raw `.eml` to `conversations/{conversationId}/{messageId}`
   - Extracts PDF and DOCX attachments from MIME, saves to `attachments/`
   - Creates or updates DynamoDB conversation record (including
     `displayName` for LinkedIn senders)
   - Deletes from staging

#### Reply Handler

1. Reads raw `.eml` from `staging/{messageId}` in S3
2. Extracts `conversationId` from the recipient address
   (`{conversationId}@thread.denverbytes.com`)
3. Looks up original sender email via DynamoDB `GetItem` on `conversationId`,
   retrieving the `senderEmail` attribute
4. Parses metadata commands (`[COMPANY: ...]`, `[TITLE: ...]`, etc.)
5. Updates DynamoDB with any extracted metadata
6. Strips `--- METADATA ---` section and all quoted reply lines (`>`)
7. Enqueues clean reply to `reply-queue` with original sender as recipient
8. Archives raw reply to `conversations/{conversationId}/{messageId}`
9. Deletes from staging

#### Attachment Extractor

1. Triggered by S3 `ObjectCreated` events on `attachments/*.pdf` and
   `attachments/*.docx`
2. Extracts text using `pypdf` (PDF) or `python-docx` (DOCX)
3. Writes extracted text to `extracted-text/{conversationId}/{messageId}/{filename}.txt`

### Sender Lambdas

Three dedicated Lambdas consume from SQS queues and call SES to send email.
All three implement the same exponential backoff retry pattern:

- **Retry schedule**: immediate, 5s, 30s, 120s (4 in-Lambda attempts)
- **Retryable errors**: `MailFromDomainNotVerifiedException`, `Throttling`,
  `ServiceUnavailable`
- **SQS safety net**: if the Lambda raises after exhausting retries, SQS
  redelivers up to 5 times (`maxReceiveCount=5`), then routes to DLQ

| Lambda | Queue | Sends to | Purpose |
|--------|-------|----------|---------|
| ack-sender | ack-queue | External Sender | Auto-acknowledgement |
| forward-sender | forward-queue | Private Mailbox | Forward inbound email |
| reply-sender | reply-queue | External Sender | Route reply to original sender |

## Summary

```
SES        = transport (receive + send, DKIM signing, MAIL FROM)
Lambda     = logic (parse, filter, enrich, route, extract, retry)
SQS        = decoupling + retry (3 queues + 3 DLQs, exponential backoff)
S3         = storage (raw emails, attachments, extracted text, spam archive)
DynamoDB   = state (conversation metadata per sender, sender email lookup)
CloudWatch = observability (structured logs, error alarms, DLQ depth alarms)
```
