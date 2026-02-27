# Service Email Handler

## Personal Email Routing and Conversation Tracking

An AWS-based email pipeline that receives inbound email at a public address, filters spam,
auto-acknowledges first contact, forwards to a private mailbox, and routes replies back to
the original sender — while maintaining a searchable DynamoDB record per contact for job
search tracking.

Repository: [github.com/stephenabbot/service-email-handler](https://github.com/stephenabbot/service-email-handler)

---

## What Problem This Project Solves

A single public address (`stephen.abbot@denverbytes.com`) receives sent to <stephen.abbot@denverbytes.com>.

Without automation:

- Spam and bulk mail mixes with legitimate contacts, requiring manual triage
- First-contact senders receive no acknowledgement
- Replies from a private mailbox expose that address to external senders
- There is no structured record of conversations for job search tracking

---

## What This Project Does

- **Filters spam** in three stages: SES verdict flags, recipient address validation, and
  PCRE2 pattern matching on sender domain, subject, and body
- **Auto-acknowledges** first contact from each unique sender
- **Forwards** legitimate email to a private mailbox with a thread reply-to address and a
  metadata footer appended
- **Routes replies** from the private mailbox back to the original sender via a
  `thread.denverbytes.com` subdomain, stripping quoted history and metadata commands
  before delivery
- **Extracts text** from PDF and DOCX attachments and stores it in S3
- **Tracks conversations** in DynamoDB — one item per sender, updated on every inbound
  email, with 8 GSIs for querying by company, title, location, and more
- **Authenticates outbound mail** with DKIM, SPF, and custom MAIL FROM so recipients see
  the sender as verified

---

## What This Project Changes

Deploying this project creates or modifies the following AWS resources:

**SES**

- Domain identity (`denverbytes.com`) with DKIM verification
- Custom MAIL FROM domain (`mail.denverbytes.com`) for DMARC SPF alignment
- Receipt rule set with two rules: inbound handler and reply handler

**Lambda**

- `service-email-handler-prd-inbound-handler` — processes inbound mail
- `service-email-handler-prd-reply-handler` — routes replies to original senders
- `service-email-handler-prd-attachment-extractor` — extracts text from PDF/DOCX

**S3**

- Single bucket for email archive, attachments, extracted text, and spam archive
- S3 event notifications trigger the attachment extractor Lambda

**DynamoDB**

- Table `service-email-handler-prd-conversations` with 8 GSIs for querying

**CloudWatch / SNS**

- Four managed log groups with 365-day retention
- CloudWatch error alarms per Lambda function
- SNS topic for alarm notifications via email

**Route53**

- MX records for `denverbytes.com`, `thread.denverbytes.com`, and `mail.denverbytes.com`
- SPF TXT records for `denverbytes.com` and `mail.denverbytes.com`
- DMARC TXT record at `_dmarc.denverbytes.com`
- Three DKIM CNAME records at `*._domainkey.denverbytes.com`

**IAM**

- Least-privilege execution roles for each Lambda function

---

## Technology Stack

| Technology | Purpose | Notes |
|------------|---------|-------|
| AWS SES | Email transport — receive, send, DKIM signing | Custom MAIL FROM for DMARC alignment |
| AWS Lambda | Business logic — inbound, reply routing, text extraction | Python 3.12, x86_64 |
| AWS S3 | Email archive, attachments, extracted text, spam archive | AES256 encryption |
| AWS DynamoDB | Conversation metadata — one item per sender | PAY_PER_REQUEST, 8 GSIs |
| AWS CloudWatch | Structured logs, error alarms | 365-day log retention |
| AWS SNS | Alarm notification delivery | Email subscription |
| AWS Route53 | MX, DKIM, SPF, DMARC, custom MAIL FROM DNS records | |
| AWS SSM | Terraform backend config, spam keywords indirection | |
| OpenTofu / Terraform | Infrastructure as code | Script auto-detects which is installed |
| Python 3.12 | Lambda runtime | `pcre2`, `pypdf`, `python-docx` |
| Podman | Lambda package builds | `--platform linux/amd64` required on Apple Silicon |

---

## Quick Start

### 1. Configure

Edit `config.env` with your settings:

```bash
# Tags
TAG_COST_CENTER=default
TAG_ENVIRONMENT=prd
TAG_OWNER=YourName

# Email
CONTACT_EMAIL=your.public@yourdomain.com
PRIVATE_EMAIL=your.private@example.com
DOMAIN_NAME=yourdomain.com

# AWS
AWS_REGION=us-east-1
```

### 2. Deploy

```bash
./scripts/deploy.sh
```

Confirm the SNS subscription email that arrives after deployment to receive CloudWatch
alarm notifications.

### 3. Destroy

```bash
./scripts/destroy.sh
```

---

## Documentation

- [Architecture](docs/architecture.md) — System design, email flow, data model, email authentication
- [Prerequisites](docs/prerequisites.md) — AWS setup, required tools, SSM parameters
- [Operations](docs/operations.md) — Scripts reference, spam filter management, monitoring
- [Usage](docs/usage.md) — Receiving mail, replying, metadata commands, searching conversations
- [Troubleshooting](docs/troubleshooting.md) — Common issues and solutions
- [Tags](docs/tags.md) — Resource tagging reference

---

## Security

- S3 bucket: AES256 encryption, all public access blocked
- SES bucket policy: SES may only write to the `staging/` prefix
- IAM: least-privilege execution roles scoped to specific resources
- DKIM signing on all outbound mail
- DMARC policy: `p=quarantine` with 100% coverage

---

© Stephen Abbot
