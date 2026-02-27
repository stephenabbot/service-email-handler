# Usage

## How Email Handling Works

### Receiving an email

When an external sender emails `stephen.abbot@denverbytes.com`:

1. SES receives the message, stores the raw `.eml` at `staging/{messageId}` in S3, and
   invokes the inbound Lambda
2. The Lambda runs the three-gate spam check. If any gate fails, the email is archived to
   `spam/{YYYY-MM-DD}/` and discarded
3. If legitimate and first contact, an auto-acknowledgement is enqueued to the `ack-queue`.
   The `ack-sender` Lambda picks it up and sends from `stephen.abbot@denverbytes.com`
   with exponential backoff retry
4. The message is enqueued to the `forward-queue`. The `forward-sender` Lambda sends it
   to the configured private mailbox with:
   - `Reply-To` set to `{conversationId}@thread.denverbytes.com`
   - A metadata footer appended to the body
5. The raw `.eml` is archived to `conversations/{conversationId}/{messageId}`
6. PDF and DOCX attachments are extracted and saved to
   `attachments/{conversationId}/{messageId}/`

The metadata footer in the forwarded email looks like:

```
--- METADATA ---
Reply-To: stabbot-at-hotmail.com@thread.denverbytes.com
Original Sender: stabbot@hotmail.com
Conversation ID: stabbot-at-hotmail.com
```

### Replying

To reply to a contact, reply from the private mailbox to the `Reply-To` address shown in
the forwarded email — `{conversationId}@thread.denverbytes.com`. Do not reply directly to
the sender's address.

The reply handler:

1. Extracts the `conversationId` from the thread address
2. Looks up the original sender's email via DynamoDB `GetItem` on the `conversationId`
   key, retrieving the `senderEmail` attribute
3. Strips all quoted reply history (lines starting with `>`) and the `--- METADATA ---`
   section
4. Enqueues the clean reply to the `reply-queue`. The `reply-sender` Lambda sends it to
   the original sender from `stephen.abbot@denverbytes.com` with exponential backoff retry

The original sender receives a clean reply with no indication of the underlying system.

### Send failures and retries

All outbound sends (ack, forward, reply) go through SQS queues with dedicated sender
Lambdas that implement exponential backoff (immediate, 5s, 30s, 120s). If all in-Lambda
retries fail, SQS redelivers up to 5 times. After that, the message moves to a
dead-letter queue (DLQ) and a CloudWatch alarm fires, sending an email alert.

DLQ messages can be inspected and redriven — see [Operations](operations.md#dlq-inspection-and-redrive).

---

## Conversation Threading

- One conversation per sender email address, for the lifetime of the system
- **Standard senders**: `conversationId` is derived from the sender address:
  `user@domain.com` → `user-at-domain.com`
- **LinkedIn senders** (`*@bounce.linkedin.com`): the display name is extracted from the
  `From` header, slugified, and suffixed with `-linkedin`. For example:
  `Jane Smith <s-2kfv...@bounce.linkedin.com>` → `jane-smith-linkedin`
- The `displayName` is stored in DynamoDB for LinkedIn senders (e.g. "Jane Smith")
- The auto-acknowledgement is sent only on first contact — determined by whether a
  DynamoDB record already exists for that `conversationId`
- All emails from the same sender, regardless of subject or date, are grouped under the
  same `conversationId`
- `firstContactDate` is write-once and is never overwritten by subsequent emails
- The reply handler resolves `conversationId` → original sender email via DynamoDB
  `GetItem` (not string reversal), which supports both standard and LinkedIn conversation IDs

---

## Metadata Commands

Include metadata commands anywhere in a reply body to update the DynamoDB conversation
record for that sender:

```
[COMPANY: Acme Corp]
[TITLE: Senior Engineer]
[TYPE: Direct]
[LOCATION: San Francisco, CA]
[SALARY_RANGE: 150-200k]
[JOB_ID: ABC123]
[NOTES: Follow up after April 15]
```

All fields are optional. The latest values overwrite previous ones. Commands can appear
anywhere in the reply body — they are extracted and then stripped before the clean reply
is sent.

To record metadata without sending any content to the external sender, place only metadata
commands in the reply above the `--- METADATA ---` line. The handler strips everything
after `--- METADATA ---` before sending.

---

## Searching Conversations

Query the DynamoDB table `service-email-handler-prd-conversations` using any of the 8
GSIs. Items only appear in a GSI once the relevant metadata field has been set via a
metadata command.

Add queries to `z_runcommands.sh` and run:

```bash
bash z_runcommands.sh && cat z_command_outputs.txt
```

**All conversations with a company**:

```bash
aws dynamodb query \
    --table-name service-email-handler-prd-conversations \
    --index-name companyName-timestamp-index \
    --key-condition-expression "companyName = :company" \
    --expression-attribute-values '{":company": {"S": "Acme Corp"}}' \
    --output json >> z_command_outputs.txt
```

**Look up a conversation by sender email**:

```bash
aws dynamodb get-item \
    --table-name service-email-handler-prd-conversations \
    --key '{"conversationId": {"S": "sender-at-domain.com"}}' \
    --output json >> z_command_outputs.txt
```
