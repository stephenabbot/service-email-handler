# Troubleshooting

All operational investigation uses `z_runcommands.sh`. Add the relevant AWS CLI queries to
the script and run:

```bash
bash z_runcommands.sh && cat z_command_outputs.txt
```

---

## Outbound mail shows "Unverified" in recipient mail client

### Symptom

Recipient mail client (e.g. Outlook) shows the sender as "Unverified" or displays a
security warning next to the message.

### Cause

DMARC is not fully passing. Both conditions must be met simultaneously: DKIM verification
status must be `Success` and the custom MAIL FROM domain status must be `Success`.

### Solutions

**1. Check DKIM status**

Add to `z_runcommands.sh`:
```bash
aws ses get-identity-dkim-attributes \
    --identities denverbytes.com \
    --output json >> z_command_outputs.txt
```

`DkimVerificationStatus` must be `Success`. If it shows `Failed` despite correct CNAME
records in DNS, re-trigger verification:
```bash
aws ses verify-domain-dkim \
    --domain denverbytes.com >> z_command_outputs.txt
```
SES re-checks within minutes of the trigger.

**2. Check custom MAIL FROM status**

```bash
aws ses get-identity-mail-from-domain-attributes \
    --identities denverbytes.com \
    --output json >> z_command_outputs.txt
```

`MailFromDomainStatus` must be `Success`. If not, verify the MX and SPF records for
`mail.denverbytes.com` are present in Route53. These are managed by Terraform — run
`./scripts/deploy.sh` to ensure they are applied.

**3. Check behavior_on_mx_failure setting**

```bash
aws sesv2 get-email-identity \
    --email-identity denverbytes.com \
    --query 'MailFromAttributes' \
    --output json >> z_command_outputs.txt
```

`BehaviorOnMxFailure` should be `REJECT_MESSAGE`. If it shows `USE_DEFAULT_VALUE`, SES
may silently fall back to `amazonses.com` as the MAIL FROM domain during transient MX
failures, breaking DMARC alignment. Redeploy to fix:
```bash
./scripts/deploy.sh
```

When both are `Success`:
- DMARC SPF alignment: PASS — Return-Path is `mail.denverbytes.com`, a subdomain of
  `denverbytes.com`
- DMARC DKIM alignment: PASS — `d=denverbytes.com` matches the `From` header domain

---

## Email not received

### Symptom

An expected email does not arrive in the private mailbox.

### Solutions

**1. Verify SES receipt rule set is active**:
```bash
aws ses describe-active-receipt-rule-set \
    --output json >> z_command_outputs.txt
```
The active rule set should be `service-email-handler-prd-rules`.

**2. Check MX records**:
```bash
dig MX denverbytes.com >> z_command_outputs.txt
dig MX thread.denverbytes.com >> z_command_outputs.txt
```
Both should resolve to SES inbound endpoints.

**3. Check SES domain verification status**:
```bash
aws ses get-identity-verification-attributes \
    --identities denverbytes.com \
    --output json >> z_command_outputs.txt
```
`VerificationStatus` must be `Success`.

**4. Check Lambda error logs**:
```bash
aws logs filter-log-events \
    --log-group-name "/aws/lambda/service-email-handler-prd-inbound-handler" \
    --filter-pattern "ERROR" \
    --output json >> z_command_outputs.txt
```

**5. Check for unprocessed objects in staging**:
```bash
aws s3 ls s3://{bucket}/staging/ >> z_command_outputs.txt
```
Objects persisting in `staging/` indicate the Lambda failed during processing.

**6. Check the forward-sender queue and DLQ**:

The inbound handler enqueues the forward to SQS. If the forward-sender Lambda fails,
the message may be in the queue or DLQ:
```bash
aws sqs get-queue-attributes \
    --queue-url https://sqs.us-east-1.amazonaws.com/{account}/service-email-handler-prd-forward-sender \
    --attribute-names ApproximateNumberOfMessages \
    --output json >> z_command_outputs.txt

aws sqs get-queue-attributes \
    --queue-url https://sqs.us-east-1.amazonaws.com/{account}/service-email-handler-prd-forward-sender-dlq \
    --attribute-names ApproximateNumberOfMessages \
    --output json >> z_command_outputs.txt
```

**7. Check forward-sender Lambda logs**:
```bash
aws logs filter-log-events \
    --log-group-name "/aws/lambda/service-email-handler-prd-forward-sender" \
    --filter-pattern "ERROR" \
    --output json >> z_command_outputs.txt
```

---

## Lambda ImportModuleError at runtime

### Symptom

```
Runtime.ImportModuleError: cannot import name '_cy' from 'pcre2'
```
or
```
Runtime.ImportModuleError: No module named 'pcre2._pcre2'
```

### Cause

The Lambda package was compiled for `arm64` (Apple Silicon default) but Lambda runs on
`x86_64`. Native extensions built for the wrong architecture fail at import.

### Solution

Ensure all `podman run` commands in `scripts/deploy.sh` and `scripts/deploy_spam_filter.sh`
include `--platform linux/amd64`. Then redeploy:

```bash
./scripts/deploy.sh
```

---

## Emails stuck in staging

### Symptom

Objects in `s3://{bucket}/staging/` are not being deleted after processing.

### Cause

Lambda processing failed after reading the object but before completing all steps. The
delete step was never reached, so the object persists.

### Solutions

1. Check CloudWatch Logs for the Lambda that should have processed the object (inbound or
   reply handler based on the message ID):
   ```bash
   aws logs filter-log-events \
       --log-group-name "/aws/lambda/service-email-handler-prd-inbound-handler" \
       --filter-pattern "handler_failed" \
       --output json >> z_command_outputs.txt
   ```

2. Identify the error and resolve the underlying cause.

3. Manually delete the staging object after investigation:
   ```bash
   aws s3 rm s3://{bucket}/staging/{messageId} >> z_command_outputs.txt
   ```

---

## Auto-acknowledgement not sent

### Symptom

A first-contact sender does not receive an acknowledgement email.

### Solutions

**1. Confirm it is actually first contact** — look up the `conversationId` in DynamoDB:

`conversationId` for `user@domain.com` is `user-at-domain.com`.

```bash
aws dynamodb get-item \
    --table-name service-email-handler-prd-conversations \
    --key '{"conversationId": {"S": "sender-at-domain.com"}}' \
    --output json >> z_command_outputs.txt
```

If a record exists with `firstContactDate`, this sender has contacted before and no
acknowledgement is sent (correct behavior).

**2. Check inbound handler logs** for enqueue failure:
```bash
aws logs filter-log-events \
    --log-group-name "/aws/lambda/service-email-handler-prd-inbound-handler" \
    --filter-pattern "ack_enqueue_failed" \
    --output json >> z_command_outputs.txt
```

**3. Check the ack-sender queue and DLQ**:
```bash
aws sqs get-queue-attributes \
    --queue-url https://sqs.us-east-1.amazonaws.com/{account}/service-email-handler-prd-ack-sender \
    --attribute-names ApproximateNumberOfMessages \
    --output json >> z_command_outputs.txt

aws sqs get-queue-attributes \
    --queue-url https://sqs.us-east-1.amazonaws.com/{account}/service-email-handler-prd-ack-sender-dlq \
    --attribute-names ApproximateNumberOfMessages \
    --output json >> z_command_outputs.txt
```

**4. Check ack-sender Lambda logs** for send failures:
```bash
aws logs filter-log-events \
    --log-group-name "/aws/lambda/service-email-handler-prd-ack-sender" \
    --filter-pattern "ack_send_failed" \
    --output json >> z_command_outputs.txt
```

**5. Verify SES sending limits**:
```bash
aws ses get-send-quota --output json >> z_command_outputs.txt
```

---

## Reply not delivered to original sender

### Symptom

A reply sent from the private mailbox to `{conversationId}@thread.denverbytes.com` does
not reach the original sender.

### Solutions

**1. Verify the DynamoDB record exists** for the `conversationId`. The reply handler
looks up `senderEmail` via `GetItem`:
```bash
aws dynamodb get-item \
    --table-name service-email-handler-prd-conversations \
    --key '{"conversationId": {"S": "sender-at-domain.com"}}' \
    --output json >> z_command_outputs.txt
```

If no record exists, the reply handler logs `sender_not_found` and sends an SNS alert.

**2. Check reply handler logs** for lookup failure:
```bash
aws logs filter-log-events \
    --log-group-name "/aws/lambda/service-email-handler-prd-reply-handler" \
    --filter-pattern "sender_not_found" \
    --output json >> z_command_outputs.txt
```

**3. Check the reply-sender queue and DLQ**:
```bash
aws sqs get-queue-attributes \
    --queue-url https://sqs.us-east-1.amazonaws.com/{account}/service-email-handler-prd-reply-sender \
    --attribute-names ApproximateNumberOfMessages \
    --output json >> z_command_outputs.txt

aws sqs get-queue-attributes \
    --queue-url https://sqs.us-east-1.amazonaws.com/{account}/service-email-handler-prd-reply-sender-dlq \
    --attribute-names ApproximateNumberOfMessages \
    --output json >> z_command_outputs.txt
```

**4. Check reply-sender Lambda logs**:
```bash
aws logs filter-log-events \
    --log-group-name "/aws/lambda/service-email-handler-prd-reply-sender" \
    --filter-pattern "reply_send_failed" \
    --output json >> z_command_outputs.txt
```

**5. Check for handler errors**:
```bash
aws logs filter-log-events \
    --log-group-name "/aws/lambda/service-email-handler-prd-reply-handler" \
    --filter-pattern "handler_failed" \
    --output json >> z_command_outputs.txt
```

---

## Messages in dead-letter queue (DLQ)

### Symptom

CloudWatch alarm fires for DLQ depth ≥ 1, or you receive an SNS alert about a DLQ.

### Cause

An outbound email send failed after all retries (4 in-Lambda retries × 5 SQS redeliveries
= up to 20 total attempts). Common causes:
- Sustained `MailFromDomainNotVerifiedException` (custom MAIL FROM MX down)
- SES throttling beyond retry window
- Invalid recipient address
- SES account sending limits exceeded

### Solutions

**1. Inspect the DLQ messages** to see which emails failed and why:
```bash
aws sqs receive-message \
    --queue-url https://sqs.us-east-1.amazonaws.com/{account}/service-email-handler-prd-{name}-dlq \
    --max-number-of-messages 10 \
    --visibility-timeout 0 \
    --output json >> z_command_outputs.txt
```

**2. Check the sender Lambda logs** for the error details:
```bash
aws logs filter-log-events \
    --log-group-name "/aws/lambda/service-email-handler-prd-{name}" \
    --filter-pattern "send_exhausted" \
    --output json >> z_command_outputs.txt
```

**3. Fix the underlying issue** (e.g., verify MAIL FROM MX is healthy, check SES limits).

**4. Redrive the DLQ messages** back to the main queue:
```bash
aws sqs start-message-move-task \
    --source-arn arn:aws:sqs:us-east-1:{account}:service-email-handler-prd-{name}-dlq \
    --destination-arn arn:aws:sqs:us-east-1:{account}:service-email-handler-prd-{name}
```

**5. Monitor** that the redriven messages process successfully.

DLQ messages have 7-day retention. Messages not redriven within 7 days are permanently lost.

---

## Spam filter validation error

### Symptom

```
Error: Invalid regex in subject_patterns: <pattern>
```

### Cause

A pattern in `spam-filter/keywords.txt` is not valid PCRE2 syntax.

### Solution

Test the pattern at [regex101.com](https://regex101.com) using PCRE2 mode. Correct the
syntax in `spam-filter/keywords.txt`, then redeploy:

```bash
./scripts/deploy_spam_filter.sh
```
