# Operations

## Scripts

### deploy.sh

**Purpose**: Full infrastructure deploy — builds Lambda packages, runs Terraform, deploys
spam filter.

```bash
./scripts/deploy.sh
```

**What it does**:

1. Runs prerequisite checks (`verify-prerequisites.sh`)
2. Detects partial deployments — exits with an error if some but not all core resources
   exist (to prevent Terraform conflicts)
3. Starts the Podman machine if it is not running
4. Builds each Lambda package using Podman with `--platform linux/amd64`
5. Detects OpenTofu or Terraform (prefers OpenTofu)
6. Reads Terraform backend config from SSM (`/terraform/foundation/s3-state-bucket`,
   `/terraform/foundation/dynamodb-lock-table`)
7. Runs `tofu init` / `terraform init` with the S3 backend
8. Imports existing S3 bucket into Terraform state if it exists outside state
9. Runs `tofu apply` / `terraform apply`
10. Uploads Lambda packages to S3 after the bucket is created
11. Calls `deploy_spam_filter.sh` to upload the initial keyword patterns

**Requirements**:

- `config.env` present and configured
- AWS credentials configured
- OpenTofu or Terraform installed
- Podman installed
- SSM parameters present: `/terraform/foundation/s3-state-bucket`,
  `/terraform/foundation/dynamodb-lock-table`,
  `/static-website/infrastructure/{DOMAIN_NAME}/hosted-zone-id`

**Example**:

```bash
./scripts/deploy.sh
```

After deployment, confirm the SNS subscription email to enable CloudWatch alarm
notifications.

If a partial deployment is detected, destroy first:

```bash
./scripts/destroy.sh
./scripts/deploy.sh
```

---

### destroy.sh

**Purpose**: Tear down all infrastructure, including pre-cleanup of resources that
Terraform cannot destroy without manual preparation.

```bash
./scripts/destroy.sh
```

**What it does**:

1. Runs prerequisite checks
2. Deactivates the SES receipt rule set (required before deletion)
3. Deletes SES receipt rule sets for this project
4. Empties the S3 bucket
5. Deletes Lambda functions
6. Runs `tofu destroy` / `terraform destroy`

**Requirements**:

- `config.env` present
- AWS credentials configured
- Terraform state present

**Example**:

```bash
./scripts/destroy.sh
```

---

### deploy_spam_filter.sh

**Purpose**: Update spam filter keyword patterns without a full infrastructure redeploy.
Run this whenever `spam-filter/keywords.txt` is edited.

```bash
./scripts/deploy_spam_filter.sh
```

**What it does**:

1. Reads `spam-filter/keywords.txt`
2. Validates every PCRE2 pattern using Podman with the same Python image as Lambda builds
   (ensures the pcre2 version matches the Lambda runtime exactly)
3. Alphabetizes patterns within each section
4. Uploads the validated file to `s3://{bucket}/spam-filter/keywords.txt`

Warm Lambda containers pick up the new keywords within 5 minutes (TTL-based cache). Cold
starts pick them up immediately.

**Requirements**:

- `config.env` present
- AWS credentials configured
- Infrastructure already deployed (S3 bucket must exist)
- Podman installed and running

**Example**:

```bash
# Edit patterns
vim spam-filter/keywords.txt

# Validate and deploy
./scripts/deploy_spam_filter.sh
```

---

## Spam Filter Management

### Pattern format

`spam-filter/keywords.txt` uses three named sections:

```text
--- BLOCKED_SENDER_DOMAINS ---
.*\.ru$
spam\.com

--- SUBJECT_PATTERNS ---
\blottery\b
urgent.*wire

--- BODY_PATTERNS ---
click\s+here\s+to\s+claim
wire\s+transfer
```

All patterns are PCRE2 regex, matched case-insensitively. A match in any section marks
the email as spam. Test patterns at [regex101.com](https://regex101.com) using PCRE2 mode
before deploying.

### Updating patterns

1. Edit `spam-filter/keywords.txt`
2. Run `./scripts/deploy_spam_filter.sh`

The script validates syntax and alphabetizes each section before uploading. Invalid
patterns cause the script to exit without uploading.

---

## Monitoring

### Log Groups

All 7 log groups have 365-day retention:

| Log Group | Contents |
|-----------|----------|
| `/aws/lambda/service-email-handler-prd-inbound-handler` | Inbound processing events |
| `/aws/lambda/service-email-handler-prd-reply-handler` | Reply routing events |
| `/aws/lambda/service-email-handler-prd-attachment-extractor` | Text extraction events |
| `/aws/lambda/service-email-handler-prd-ack-sender` | Ack send attempts and retries |
| `/aws/lambda/service-email-handler-prd-forward-sender` | Forward send attempts and retries |
| `/aws/lambda/service-email-handler-prd-reply-sender` | Reply send attempts and retries |
| `/email-handler/spam` | Spam detection events |

### CloudWatch Alarms

9 alarms, all publishing to the SNS alert topic:

| Alarm | Metric | Threshold | Purpose |
|-------|--------|-----------|---------|
| `inbound-handler-errors` | Lambda Errors | ≥ 1 / 60s | Inbound processing failure |
| `reply-handler-errors` | Lambda Errors | ≥ 1 / 60s | Reply processing failure |
| `attachment-extractor-errors` | Lambda Errors | ≥ 1 / 60s | Text extraction failure |
| `ack-sender-errors` | Lambda Errors | ≥ 1 / 60s | Ack send failure |
| `forward-sender-errors` | Lambda Errors | ≥ 1 / 60s | Forward send failure |
| `reply-sender-errors` | Lambda Errors | ≥ 1 / 60s | Reply send failure |
| `ack-sender-dlq-depth` | SQS ApproximateNumberOfMessagesVisible | ≥ 1 / 60s | Ack permanently failed |
| `forward-sender-dlq-depth` | SQS ApproximateNumberOfMessagesVisible | ≥ 1 / 60s | Forward permanently failed |
| `reply-sender-dlq-depth` | SQS ApproximateNumberOfMessagesVisible | ≥ 1 / 60s | Reply permanently failed |

Confirm the SNS subscription email after deployment to activate notifications.

### SQS Queue Monitoring

Check queue depths and DLQ status:

```bash
# Check all queue depths
aws sqs get-queue-attributes \
    --queue-url https://sqs.us-east-1.amazonaws.com/{account}/service-email-handler-prd-ack-sender \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --output json >> z_command_outputs.txt

# Check DLQ depths
aws sqs get-queue-attributes \
    --queue-url https://sqs.us-east-1.amazonaws.com/{account}/service-email-handler-prd-ack-sender-dlq \
    --attribute-names ApproximateNumberOfMessages \
    --output json >> z_command_outputs.txt
```

### DLQ Inspection and Redrive

When a DLQ alarm fires, inspect the failed messages:

```bash
# Peek at DLQ messages (does not delete them)
aws sqs receive-message \
    --queue-url https://sqs.us-east-1.amazonaws.com/{account}/service-email-handler-prd-ack-sender-dlq \
    --max-number-of-messages 10 \
    --visibility-timeout 0 \
    --output json >> z_command_outputs.txt
```

To redrive messages back to the main queue after fixing the underlying issue:

```bash
aws sqs start-message-move-task \
    --source-arn arn:aws:sqs:us-east-1:{account}:service-email-handler-prd-ack-sender-dlq \
    --destination-arn arn:aws:sqs:us-east-1:{account}:service-email-handler-prd-ack-sender
```

DLQ messages have 7-day retention. Messages not redriven or deleted within 7 days are
permanently lost.
