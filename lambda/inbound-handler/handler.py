import json
import os
import re
import hashlib
import time
import boto3
import pcre2
from email import policy
from email.parser import BytesParser
from email.utils import parseaddr
from datetime import datetime
from mypylogger import get_logger

logger = get_logger(__name__)

s3 = boto3.client('s3')
sqs = boto3.client('sqs')
dynamodb = boto3.resource('dynamodb')
sns = boto3.client('sns')
ssm = boto3.client('ssm')
logs = boto3.client('logs')

BUCKET_NAME = os.environ['BUCKET_NAME']
TABLE_NAME = os.environ['TABLE_NAME']
PRIVATE_EMAIL = os.environ['PRIVATE_EMAIL']
PUBLIC_EMAIL = os.environ['PUBLIC_EMAIL']
DOMAIN_NAME = os.environ['DOMAIN_NAME']
SNS_TOPIC_ARN = os.environ['SNS_TOPIC_ARN']
SPAM_KEYWORDS_SSM_PARAM = os.environ['SPAM_KEYWORDS_SSM_PARAM']
ACK_QUEUE_URL = os.environ['ACK_QUEUE_URL']
FORWARD_QUEUE_URL = os.environ['FORWARD_QUEUE_URL']

SPAM_LOG_GROUP = '/email-handler/spam'
SPAM_KEYWORDS_TTL = 300  # seconds; reload keywords after 5 minutes

spam_keywords = None
spam_keywords_loaded_at = 0.0

def load_spam_keywords():
    global spam_keywords, spam_keywords_loaded_at
    now = time.time()
    if spam_keywords is not None and (now - spam_keywords_loaded_at) < SPAM_KEYWORDS_TTL:
        return spam_keywords

    try:
        param_response = ssm.get_parameter(Name=SPAM_KEYWORDS_SSM_PARAM)
        s3_key = param_response['Parameter']['Value']

        obj = s3.get_object(Bucket=BUCKET_NAME, Key=s3_key)
        content = obj['Body'].read().decode('utf-8')

        loaded = {
            "blocked_sender_domains": [],
            "subject_patterns": [],
            "body_patterns": []
        }

        current_section = None
        for line in content.split('\n'):
            line = line.strip()
            if not line or line.startswith('#'):
                continue

            if line == '--- BLOCKED_SENDER_DOMAINS ---':
                current_section = 'blocked_sender_domains'
            elif line == '--- SUBJECT_PATTERNS ---':
                current_section = 'subject_patterns'
            elif line == '--- BODY_PATTERNS ---':
                current_section = 'body_patterns'
            elif current_section:
                loaded[current_section].append(line)

        spam_keywords = loaded
        spam_keywords_loaded_at = now
        return spam_keywords
    except Exception as e:
        logger.error("failed_to_load_spam_keywords", extra={"error": str(e)})
        return {"blocked_sender_domains": [], "subject_patterns": [], "body_patterns": []}


def slugify(text):
    text = text.lower().strip()
    text = re.sub(r'[^a-z0-9\s-]', '', text)
    text = re.sub(r'[\s-]+', '-', text)
    return text.strip('-')


def extract_display_name(msg):
    from_header = msg.get('From', '')
    display_name, _ = parseaddr(from_header)
    return display_name if display_name else None


def email_to_conversation_id(sender_email, display_name=None):
    domain = sender_email.split('@')[1] if '@' in sender_email else ''

    if domain == 'bounce.linkedin.com' and display_name:
        slug = slugify(display_name)
        return f"{slug}-linkedin"

    return sender_email.replace('@', '-at-')


def is_first_contact(sender_email):
    # Table has only conversationId as hash key (no sort key), so get_item works correctly.
    table = dynamodb.Table(TABLE_NAME)
    conversation_id = email_to_conversation_id(sender_email)

    try:
        response = table.get_item(Key={'conversationId': conversation_id})
        return 'Item' not in response
    except Exception as e:
        logger.error("dynamodb_check_failed", extra={"error": str(e), "sender": sender_email})
        return False


def enqueue_acknowledgement(sender_email, subject):
    try:
        with open('auto-acknowledgement.txt', 'r') as f:
            body = f.read()

        sqs.send_message(
            QueueUrl=ACK_QUEUE_URL,
            MessageBody=json.dumps({
                'recipient': sender_email,
                'subject': 'Thank you for reaching out',
                'body': body
            })
        )
        logger.info("ack_enqueued", extra={
            "recipient": sender_email,
            "subject": subject
        })
    except Exception as e:
        logger.error("ack_enqueue_failed", extra={"error": str(e), "recipient": sender_email})
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="Inbound Handler: Ack Enqueue Failed",
            Message=f"Failed to enqueue acknowledgement for {sender_email}: {str(e)}"
        )


def enqueue_forward(sender_email, subject, body, conversation_id):
    reply_to = f"{conversation_id}@thread.{DOMAIN_NAME}"
    footer = f"\n\n--- METADATA ---\nReply-To: {reply_to}\nOriginal Sender: {sender_email}\nConversation ID: {conversation_id}"

    try:
        sqs.send_message(
            QueueUrl=FORWARD_QUEUE_URL,
            MessageBody=json.dumps({
                'recipient': PRIVATE_EMAIL,
                'subject': f"Fwd: {subject}",
                'body': body + footer,
                'reply_to': reply_to
            })
        )
        logger.info("forward_enqueued", extra={
            "sender": sender_email,
            "conversation_id": conversation_id,
            "subject": subject,
            "body_preview": body[:500]
        })
    except Exception as e:
        logger.error("forward_enqueue_failed", extra={"error": str(e), "sender": sender_email})
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="Inbound Handler: Forward Enqueue Failed",
            Message=f"Failed to enqueue forward for {sender_email}: {str(e)}"
        )


def store_conversation(conversation_id, sender_email, subject, body_text, display_name=None):
    # Uses update_item with if_not_exists for firstContactDate so follow-up emails
    # update lastMessageBody/timestamp without overwriting the original contact date.
    table = dynamodb.Table(TABLE_NAME)
    timestamp = datetime.utcnow().isoformat()

    try:
        update_expr = (
            'SET senderEmail = :email, emailDomain = :domain, '
            'subject = :subject, lastMessageBody = :body, '
            '#ts = :ts, '
            'firstContactDate = if_not_exists(firstContactDate, :ts)'
        )
        expr_values = {
            ':email': sender_email,
            ':domain': sender_email.split('@')[1] if '@' in sender_email else '',
            ':subject': subject,
            ':body': body_text[:1000],
            ':ts': timestamp,
        }

        if display_name:
            update_expr += ', displayName = :dn'
            expr_values[':dn'] = display_name

        table.update_item(
            Key={'conversationId': conversation_id},
            UpdateExpression=update_expr,
            ExpressionAttributeNames={'#ts': 'timestamp'},
            ExpressionAttributeValues=expr_values
        )
    except Exception as e:
        logger.error("dynamodb_store_failed", extra={"error": str(e), "conversation_id": conversation_id})
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="Inbound Handler: DynamoDB Store Failed",
            Message=f"Failed to store conversation {conversation_id}: {str(e)}"
        )

def save_attachments(msg, conversation_id, message_id):
    for part in msg.iter_attachments():
        filename = part.get_filename()
        if not filename:
            continue
        lower = filename.lower()
        if lower.endswith('.pdf') or lower.endswith('.docx'):
            data = part.get_payload(decode=True)
            if data:
                key = f"attachments/{conversation_id}/{message_id}/{filename}"
                try:
                    s3.put_object(Bucket=BUCKET_NAME, Key=key, Body=data)
                    logger.info("attachment_saved", extra={"key": key})
                except Exception as e:
                    logger.error("attachment_save_failed", extra={"error": str(e), "filename": filename})

def check_spam(ses_record, mail, subject, body, sender_email):
    spam_verdict = ses_record['receipt'].get('spamVerdict', {}).get('status')
    virus_verdict = ses_record['receipt'].get('virusVerdict', {}).get('status')

    if spam_verdict == 'FAIL' or virus_verdict == 'FAIL':
        return True, "ses_verdict"

    destination = mail.get('destination', [])
    if not destination or destination[0] != PUBLIC_EMAIL:
        return True, "recipient_mismatch"

    keywords = load_spam_keywords()

    sender_domain = sender_email.split('@')[1] if '@' in sender_email else ''
    for pattern in keywords.get('blocked_sender_domains', []):
        try:
            compiled = pcre2.compile(pattern, pcre2.IGNORECASE)
            if compiled.search(sender_domain):
                return True, f"blocked_domain:{pattern}"
        except Exception as e:
            logger.error("regex_error_domain", extra={"pattern": pattern, "error": str(e)})

    for pattern in keywords.get('subject_patterns', []):
        try:
            compiled = pcre2.compile(pattern, pcre2.IGNORECASE)
            if compiled.search(subject):
                return True, f"subject_keyword:{pattern}"
        except Exception as e:
            logger.error("regex_error_subject", extra={"pattern": pattern, "error": str(e)})

    body_preview = body[:10000]
    for pattern in keywords.get('body_patterns', []):
        try:
            compiled = pcre2.compile(pattern, pcre2.IGNORECASE)
            if compiled.search(body_preview):
                return True, f"body_keyword:{pattern}"
        except Exception as e:
            logger.error("regex_error_body", extra={"pattern": pattern, "error": str(e)})

    return False, None

def log_spam_to_cloudwatch(sender, subject, reason, message_id):
    try:
        logs.create_log_group(logGroupName=SPAM_LOG_GROUP)
    except logs.exceptions.ResourceAlreadyExistsException:
        pass
    except Exception as e:
        logger.error("spam_log_group_creation_failed", extra={"error": str(e)})

    try:
        stream_name = datetime.utcnow().strftime('%Y/%m/%d')
        try:
            logs.create_log_stream(logGroupName=SPAM_LOG_GROUP, logStreamName=stream_name)
        except logs.exceptions.ResourceAlreadyExistsException:
            pass

        log_entry = {
            'timestamp': datetime.utcnow().isoformat(),
            'sender': sender,
            'subject': subject,
            'reason': reason,
            'message_id': message_id
        }

        logs.put_log_events(
            logGroupName=SPAM_LOG_GROUP,
            logStreamName=stream_name,
            logEvents=[{
                'timestamp': int(datetime.utcnow().timestamp() * 1000),
                'message': json.dumps(log_entry)
            }]
        )
    except Exception as e:
        logger.error("spam_cloudwatch_log_failed", extra={"error": str(e)})

def handle_spam(message_id, raw_email, sender, subject, reason):
    date_prefix = datetime.utcnow().strftime('%Y-%m-%d')
    spam_key = f"spam/{date_prefix}/{message_id}.eml"

    try:
        s3.put_object(Bucket=BUCKET_NAME, Key=spam_key, Body=raw_email)
        log_spam_to_cloudwatch(sender, subject, reason, message_id)
        logger.info("spam_detected", extra={"sender": sender, "reason": reason, "message_id": message_id})
    except Exception as e:
        logger.error("spam_storage_failed", extra={"error": str(e), "message_id": message_id})

def lambda_handler(event, context):
    try:
        ses_record = event['Records'][0]['ses']
        mail = ses_record['mail']
        message_id = mail['messageId']

        staging_key = f"staging/{message_id}"

        obj = s3.get_object(Bucket=BUCKET_NAME, Key=staging_key)
        raw_email = obj['Body'].read()

        msg = BytesParser(policy=policy.default).parsebytes(raw_email)
        sender_email = mail['source']
        subject = msg['subject'] or '(no subject)'
        body = msg.get_body(preferencelist=('plain',))
        body_text = body.get_content() if body else ''

        is_spam, reason = check_spam(ses_record, mail, subject, body_text, sender_email)

        if is_spam:
            handle_spam(message_id, raw_email, sender_email, subject, reason)
            s3.delete_object(Bucket=BUCKET_NAME, Key=staging_key)
            return

        display_name = extract_display_name(msg)
        conversation_id = email_to_conversation_id(sender_email, display_name)

        logger.info("email_received", extra={
            "sender": sender_email,
            "recipient": mail['destination'][0],
            "subject": subject,
            "body_preview": body_text[:500],
            "conversation_id": conversation_id,
            "display_name": display_name
        })

        first_contact = is_first_contact(sender_email)

        if first_contact:
            enqueue_acknowledgement(sender_email, subject)

        enqueue_forward(sender_email, subject, body_text, conversation_id)
        store_conversation(conversation_id, sender_email, subject, body_text, display_name)

        # Archive raw email and extract PDF/DOCX attachments
        conversations_key = f"conversations/{conversation_id}/{message_id}"
        s3.put_object(Bucket=BUCKET_NAME, Key=conversations_key, Body=raw_email)
        save_attachments(msg, conversation_id, message_id)

        s3.delete_object(Bucket=BUCKET_NAME, Key=staging_key)

    except Exception as e:
        logger.error("handler_failed", extra={"error": str(e)})
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="Inbound Handler: Unhandled Exception",
            Message=f"Unhandled exception: {str(e)}"
        )
        raise
