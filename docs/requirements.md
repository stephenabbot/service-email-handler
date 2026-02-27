# SES Email Handler — Requirements & Design

## Core Use Case

People contact you at `stephen.abbot@denverbytes.com`.
The system:

1. Receives and filters email (spam detection before any processing)
2. Auto-acknowledges first contact from each sender
3. Forwards to private mailbox with a thread reply-to address and metadata footer
4. Enables replies via the `thread.denverbytes.com` subdomain
5. Routes clean replies back to the original sender transparently
6. Builds a searchable DynamoDB record per sender for job search tracking
7. Retries all outbound sends with exponential backoff via SQS queues

## Architecture

### AWS Services

| Service | Role |
|---------|------|
| SES | Email transport — receive, send, spam/virus verdicts, DKIM signing |
| Lambda (×6) | 3 processing (inbound, reply, attachment extraction) + 3 senders (ack, forward, reply) |
| SQS | 3 send queues + 3 dead-letter queues — retry and decoupling for all outbound email |
| S3 | Email archive, attachments, extracted text, spam archive |
| DynamoDB | Conversation metadata, one item per sender |
| CloudWatch | Structured logs (7 log groups), error alarms (9 alarms) |
| SNS | Alert notifications |
| Route53 | MX, DKIM, SPF, DMARC, custom MAIL FROM DNS records |
| SSM | Backend config discovery, spam keywords indirection |

### Email Routing

| Address | Routes to |
|---------|-----------|
| `stephen.abbot@denverbytes.com` | SES inbound rule → inbound-handler Lambda |
| `*@thread.denverbytes.com` | SES reply rule → reply-handler Lambda |

### Email Authentication

All outbound mail from SES authenticates fully against DMARC:

| Record | Value |
|--------|-------|
| DKIM CNAMEs | `*._domainkey.denverbytes.com` → SES (×3) |
| SPF `denverbytes.com` | `v=spf1 include:amazonses.com ~all` |
| Custom MAIL FROM | `mail.denverbytes.com` (Return-Path subdomain) |
| SPF `mail.denverbytes.com` | `v=spf1 include:amazonses.com ~all` |
| DMARC | `v=DMARC1; p=quarantine; pct=100` |
| MAIL FROM failure | `behavior_on_mx_failure = RejectMessage` |

DMARC passes via both SPF alignment (Return-Path subdomain) and DKIM alignment.
If the custom MAIL FROM MX lookup fails, SES rejects the send rather than silently
falling back to `amazonses.com`. The sender Lambdas retry this error automatically.

## Data Model

### DynamoDB

Table: `service-email-handler-prd-conversations`

- Partition key: `conversationId` (hash-only, no sort key)
- Billing: PAY_PER_REQUEST

One item per sender, updated in-place on every inbound email.
`firstContactDate` is write-once (set via `if_not_exists`).

Metadata fields (`companyName`, `title`, `type`, `location`, `salaryRange`,
`jobId`, `notes`) are sparse — populated only when metadata commands are
included in a reply.

`displayName` is stored for LinkedIn senders (e.g. "Jane Smith").

8 GSIs, all using `timestamp` as range key:
`senderEmail`, `companyName`, `emailDomain`, `location`, `salaryRange`,
`jobId`, `type`, `title`

### S3 Layout

```
staging/                        ← Transient; deleted after processing
conversations/{convId}/{msgId}  ← Archived raw emails
attachments/{convId}/{msgId}/   ← Extracted binary attachments
extracted-text/                 ← Text extracted from PDF/DOCX
spam/{YYYY-MM-DD}/{msgId}.eml   ← Archived spam
spam-filter/keywords.txt        ← Active PCRE2 patterns
deployments/                    ← Lambda zips (30-day expiry)
```

## Spam Detection

Three-gate check in the inbound handler, applied in order:

1. **SES verdicts** — reject if `spamVerdict` or `virusVerdict` = `FAIL`
2. **Recipient check** — reject if destination ≠ `PUBLIC_EMAIL`
3. **PCRE2 patterns** — case-insensitive match on sender domain, subject,
   body (first 10 KB). Patterns loaded from S3 via SSM; cached 5 minutes.

Spam emails are archived to `spam/{date}/` and logged to `/email-handler/spam`.

## Conversation Threading

- One conversation per sender email address, for life
- **Standard senders**: `conversationId` = `sender@domain.com` → `sender-at-domain.com`
- **LinkedIn senders** (`*@bounce.linkedin.com`): display name extracted from the `From`
  header, slugified, suffixed with `-linkedin` →
  e.g. `Jane Smith <s-2kfv...@bounce.linkedin.com>` → `jane-smith-linkedin`
- Auto-acknowledgement sent on first contact only (checked via DynamoDB `GetItem`)
- Reply handler resolves `conversationId` → `senderEmail` via DynamoDB `GetItem`
  (not string reversal), supporting both standard and LinkedIn conversation IDs

## Outbound Send Retry

All outbound email is routed through SQS queues with dedicated sender Lambdas:

- **3 queues**: ack-sender, forward-sender, reply-sender (each with a paired DLQ)
- **Exponential backoff**: immediate, 5s, 30s, 120s (4 in-Lambda attempts)
- **SQS redelivery**: up to 5 times after Lambda failure (`maxReceiveCount=5`)
- **DLQ**: 7-day retention for manual inspection/redrive
- **Alerting**: CloudWatch alarm triggers on DLQ depth ≥ 1 → SNS → email

## Metadata Commands

Include metadata commands anywhere in a reply body to update the DynamoDB
conversation record:

```
[COMPANY: Acme Corp]
[TITLE: Senior Engineer]
[TYPE: Direct]
[LOCATION: San Francisco, CA]
[SALARY_RANGE: 150-200k]
[JOB_ID: ABC123]
[NOTES: Follow up after April 15]
```

## Attachment Handling

- Inbound handler extracts PDF and DOCX attachments from MIME emails
- Attachments saved to `attachments/{convId}/{messageId}/{filename}`
- S3 event triggers attachment-extractor Lambda
- Extracted text saved to `extracted-text/{convId}/{messageId}/{filename}.txt`

## Build & Deployment

- **Podman** with `--platform linux/amd64` — ensures native extensions
  (`pcre2`, `lxml`) compile for Lambda's x86_64 runtime
- **uv** for Python dependency installation inside the container
- **`./scripts/deploy.sh`** — single command for full deploy
- **`./scripts/deploy_spam_filter.sh`** — update keywords without full redeploy
- **`bash z_runcommands.sh`** — operational investigation; output to `z_command_outputs.txt`

## Constraints

- Single AWS account, single region (us-east-1)
- Personal use — low email volume
- No S3 versioning or DynamoDB point-in-time recovery
- Replies must appear to come directly from `stephen.abbot@denverbytes.com`
- No indication of proxy handling visible to external senders

## Out of Scope

- Attachment forwarding to original sender in replies
- HTML email body parsing for metadata commands
- Attachment security scanning
- AI-assisted job posting analysis
- Multi-recipient or multi-domain support
