# Architecture

## Overview

The system separates email transport from business logic. SES handles receiving, sending,
spam verdicts, and DKIM signing. All parsing, filtering, routing, and tracking is performed
exclusively in Lambda. All outbound email sends are routed through SQS queues with
dedicated sender Lambdas that implement exponential backoff retry.

```
┌──────────────────────┐            ┌──────────────────────────────┐
│  External Sender     │            │  Private Mailbox             │
│                      │            │  (abbotnh@yahoo.com)         │
└──────────┬───────────┘            └─────────────┬────────────────┘
           │ email to                             │ reply to
           │ stephen.abbot@denverbytes.com        │ {convId}@thread.denverbytes.com
           ▼                                      ▼
┌────────────────────────────────────────────────────────────────────┐
│  Amazon SES                                                        │
│  ┌─────────────────────────┐     ┌──────────────────────────────┐  │
│  │  Inbound Rule           │     │  Reply Rule                  │  │
│  │  stephen.abbot@         │     │  *@thread.denverbytes.com    │  │
│  │  denverbytes.com        │     │                              │  │
│  └────────────┬────────────┘     └──────────────┬───────────────┘  │
└───────────────┼─────────────────────────────────┼──────────────────┘
                │ stores to staging/              │ stores to staging/
                │ invokes Lambda                  │ invokes Lambda
                ▼                                 ▼
  ┌─────────────────────────┐     ┌──────────────────────────┐
  │  inbound-handler        │     │  reply-handler           │
  │  Lambda                 │     │  Lambda                  │
  └─────────┬───────────────┘     └────────────┬─────────────┘
            │                                  │
     ┌──────┼──────────────┐                   │
     ▼      ▼              ▼                   ▼
  ┌───────┐  ┌──────────┐ ┌──────────┐  ┌──────────┐
  │  S3   │  │DynamoDB  │ │  SQS     │  │  SQS     │
  │archive│  │conv.     │ │ack-queue │  │reply-    │
  │       │  │metadata  │ │fwd-queue │  │queue     │
  └──┬────┘  └──────────┘ └────┬─────┘  └────┬─────┘
     │                         │              │
     │                         ▼              ▼
     │              ┌────────────────────────────────────┐
     │              │  Sender Lambdas                    │
     │              │  ack-sender | fwd-sender | reply-  │
     │              │  sender                            │
     │              └──────────────┬─────────────────────┘
     │                             │ exponential backoff retry
     │                             ▼
     │                      ┌──────────┐
     │                      │  SES     │
     │                      │ Outbound │──→ External Sender (ack/reply)
     │                      │          │──→ Private Mailbox (forward)
     │                      └──────────┘
     │
     │ S3 ObjectCreated (attachments/*.pdf, attachments/*.docx)
     ▼
  ┌──────────────────────────┐
  │  attachment-extractor    │
  │  Lambda                  │
  │  writes to extracted-    │
  │  text/ in S3             │
  └──────────────────────────┘
```

---

## Components

### SES — Transport Layer

SES is the email transport. It does not parse MIME structure, extract headers, decode
encodings, or interpret email content. All of that is Lambda's responsibility.

**What SES does:**

- Receives inbound mail via MX records at `denverbytes.com` and `thread.denverbytes.com`
- Runs spam, virus, SPF, and DKIM checks — results surfaced as verdicts in the Lambda event
- Stores raw `.eml` at `staging/{messageId}` in S3
- Triggers the appropriate Lambda with sender, recipient, message ID, timestamp, and verdicts
- Delivers outbound mail via the `SendEmail` / `SendRawEmail` API
- Signs outbound mail with DKIM (`d=denverbytes.com`)
- Uses `mail.denverbytes.com` as the envelope sender (Return-Path) for DMARC SPF alignment
- `behavior_on_mx_failure = RejectMessage` — if the custom MAIL FROM MX lookup fails, SES
  rejects the send rather than silently falling back to `amazonses.com` (which would break
  DMARC alignment)

### Lambda — Logic Layer

Six Lambda functions contain all business logic. All run Python 3.12 on x86_64.

#### Processing Lambdas

##### inbound-handler

Triggered by the SES inbound rule for `stephen.abbot@denverbytes.com`.

1. Reads raw `.eml` from `staging/{messageId}` in S3
2. Runs three-gate spam check:
   - **Gate 1** — SES verdict flags: rejects if `spamVerdict` or `virusVerdict` = `FAIL`
   - **Gate 2** — Recipient validation: rejects if destination does not equal `PUBLIC_EMAIL`
   - **Gate 3** — PCRE2 pattern matching on sender domain, subject, and body (first 10 KB)
3. **If spam**: archives to `spam/{YYYY-MM-DD}/{messageId}.eml`, logs to `/email-handler/spam`,
   deletes from staging
4. **If legitimate**:
   - Extracts display name from the `From` header for LinkedIn senders
   - Builds conversation ID (see Conversation Identity below)
   - Checks DynamoDB for an existing conversation record — enqueues auto-acknowledgement
     to `ack-queue` on first contact only
   - Enqueues forward to `forward-queue` with `Reply-To: {conversationId}@thread.denverbytes.com`
     and a metadata footer appended to the body
   - Archives raw `.eml` to `conversations/{conversationId}/{messageId}`
   - Extracts PDF and DOCX attachments from MIME, saves to
     `attachments/{conversationId}/{messageId}/{filename}`
   - Creates or updates DynamoDB conversation record (`if_not_exists` protects
     `firstContactDate` from being overwritten on follow-up emails)
   - Stores `displayName` in DynamoDB when available (LinkedIn senders)
   - Deletes from staging

##### reply-handler

Triggered by the SES reply rule for `*@thread.denverbytes.com`.

1. Reads raw `.eml` from `staging/{messageId}` in S3
2. Extracts `conversationId` from the recipient address
   (`{conversationId}@thread.denverbytes.com`)
3. Looks up the original sender email via DynamoDB `GetItem` on the `conversationId` key,
   retrieving the `senderEmail` attribute
4. Parses metadata commands from the reply body
   (`[COMPANY: ...]`, `[TITLE: ...]`, `[TYPE: ...]`, etc.)
5. Updates DynamoDB with any extracted metadata
6. Strips the `--- METADATA ---` section and all quoted reply lines (lines starting with `>`)
7. Enqueues clean reply to `reply-queue` with the original sender as recipient
8. Archives raw reply to `conversations/{conversationId}/{messageId}`
9. Deletes from staging

##### attachment-extractor

Triggered by S3 `ObjectCreated` events on `attachments/*.pdf` and `attachments/*.docx`.

1. Extracts text using `pypdf` (PDF) or `python-docx` (DOCX)
2. Writes extracted text to `extracted-text/{conversationId}/{messageId}/{filename}.txt`

#### Sender Lambdas

Three dedicated sender Lambdas handle all outbound email via SQS:

| Lambda | Queue | Sends to | Purpose |
|--------|-------|----------|---------|
| ack-sender | ack-queue | External Sender | Auto-acknowledgement on first contact |
| forward-sender | forward-queue | Private Mailbox (Yahoo) | Forward inbound email |
| reply-sender | reply-queue | External Sender | Route reply back to original sender |

All three share the same retry pattern:
- **Exponential backoff**: immediate, 5s, 30s, 120s (4 in-Lambda attempts)
- **Retryable errors**: `MailFromDomainNotVerifiedException`, `Throttling`, `ServiceUnavailable`
- **SQS redelivery**: if the Lambda returns an error, SQS redelivers up to 5 times
  (`maxReceiveCount=5`)
- **DLQ**: after all retries exhausted, the message moves to the dead-letter queue
  (7-day retention)
- **Alerting**: SNS notification on final failure; CloudWatch alarm on DLQ depth ≥ 1

### SQS — Retry & Decoupling Layer

Three standard queues with paired dead-letter queues:

| Queue | Visibility Timeout | Retention | DLQ Retention |
|-------|-------------------|-----------|---------------|
| ack-sender | 180s | 1 day | 7 days |
| forward-sender | 180s | 1 day | 7 days |
| reply-sender | 180s | 1 day | 7 days |

Zero cost when idle — no messages stored, no Lambda invocations.

### S3 — Storage

Single bucket with the following prefix layout:

```
staging/                                              Transient: deleted after processing
conversations/{convId}/{msgId}                        Archived raw emails
attachments/{convId}/{msgId}/{filename}               Extracted binary attachments
extracted-text/{convId}/{msgId}/{filename}.txt        Text extracted from PDF/DOCX
spam/{YYYY-MM-DD}/{msgId}.eml                         Archived spam
spam-filter/keywords.txt                              Active PCRE2 patterns
deployments/                                          Lambda packages (30-day lifecycle expiry)
```

Objects that persist in `staging/` indicate a Lambda processing failure. No additional
monitoring is needed to detect failures — unprocessed objects in staging are the indicator.

### DynamoDB — State

Table: `service-email-handler-prd-conversations`

- Partition key: `conversationId` (hash-only, no sort key)
- Billing: PAY_PER_REQUEST
- One item per sender, updated in-place on every inbound email

#### Conversation Identity

`conversationId` is derived deterministically from the sender:

- **Standard senders**: `user@domain.com` → `user-at-domain.com`
- **LinkedIn senders** (`*@bounce.linkedin.com`): display name is extracted from the
  `From` header, slugified, and suffixed with `-linkedin` →
  e.g. `Jane Smith <s-2kfv...@bounce.linkedin.com>` → `jane-smith-linkedin`

The reply handler resolves `conversationId` back to the original sender email via
DynamoDB `GetItem` (retrieving the `senderEmail` attribute), rather than string reversal.
This supports both standard and LinkedIn-style conversation IDs.

`firstContactDate` is write-once — set using `if_not_exists` so follow-up emails never
overwrite it.

`displayName` is stored for LinkedIn senders (e.g. "Jane Smith").

Metadata fields (`companyName`, `title`, `type`, `location`, `salaryRange`, `jobId`,
`notes`) are sparse — populated only when metadata commands are included in a reply.

**8 GSIs** — all use `timestamp` as range key, enabling sorted range queries per attribute:

| GSI | Query pattern |
|-----|---------------|
| `senderEmail-timestamp-index` | All messages from a specific sender |
| `companyName-timestamp-index` | All conversations with a company |
| `emailDomain-timestamp-index` | All contacts from a domain |
| `location-timestamp-index` | Contacts by job location |
| `salaryRange-timestamp-index` | Contacts by salary range |
| `jobId-timestamp-index` | Lookup by job ID |
| `type-timestamp-index` | Filter by contact type (Direct) |
| `title-timestamp-index` | Filter by job title |

---

## Email Authentication

Outbound mail passes DMARC via two independent mechanisms: SPF alignment and DKIM
alignment. Both must pass for a recipient's mail client to show the sender as verified.

| Record | Type | Value | Purpose |
|--------|------|-------|---------|
| `denverbytes.com` | MX | SES inbound endpoint | Receive inbound mail |
| `thread.denverbytes.com` | MX | SES inbound endpoint | Receive thread replies |
| `mail.denverbytes.com` | MX | `10 feedback-smtp.us-east-1.amazonses.com` | Custom MAIL FROM bounce handling |
| `denverbytes.com` | TXT | `v=spf1 include:amazonses.com ~all` | SPF for the From header domain |
| `mail.denverbytes.com` | TXT | `v=spf1 include:amazonses.com ~all` | SPF for the Return-Path (MAIL FROM) domain |
| `_dmarc.denverbytes.com` | TXT | `v=DMARC1; p=quarantine; pct=100` | DMARC policy |
| `*._domainkey.denverbytes.com` | CNAME (×3) | SES DKIM endpoints | DKIM signing |

**DMARC SPF alignment**: Return-Path = `mail.denverbytes.com` — a subdomain of
`denverbytes.com`. DMARC relaxed SPF alignment passes.

**DMARC DKIM alignment**: DKIM signs with `d=denverbytes.com`, which matches the `From`
header domain. DMARC relaxed DKIM alignment passes.

**MAIL FROM failure handling**: `behavior_on_mx_failure = RejectMessage`. If the MX lookup
for `mail.denverbytes.com` fails transiently, SES rejects the send with
`MailFromDomainNotVerifiedException` rather than silently falling back to `amazonses.com`
as the MAIL FROM domain. The sender Lambdas retry this error with exponential backoff.

When both pass, Outlook and other DMARC-aware mail clients display the sender as Verified.

---

## Technology Stack

| Technology | Version / Notes |
|------------|----------------|
| Python | 3.12 |
| `pcre2` | PCRE2 regex engine for spam pattern matching |
| `pypdf` | PDF text extraction |
| `python-docx` | DOCX text extraction |
| OpenTofu / Terraform | >= 1.0 (auto-detected by deploy script) |
| Podman | `--platform linux/amd64` required on Apple Silicon |
