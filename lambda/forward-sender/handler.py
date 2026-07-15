import email.mime.application
import email.mime.multipart
import email.mime.text
import json
import mimetypes
import os
import time
import boto3
from mypylogger import get_logger

logger = get_logger(__name__)

ses = boto3.client('ses')
s3 = boto3.client('s3')
sns = boto3.client('sns')

PUBLIC_EMAIL = os.environ['PUBLIC_EMAIL']
SNS_TOPIC_ARN = os.environ['SNS_TOPIC_ARN']
BUCKET_NAME = os.environ['BUCKET_NAME']

RETRY_DELAYS = [0, 5, 30, 120]
RETRYABLE_ERRORS = {'MailFromDomainNotVerifiedException', 'Throttling', 'ServiceUnavailable'}

ICS_EXTENSIONS = {'.ics'}


def build_raw_message(recipient, subject, body, reply_to, attachment_keys):
    msg = email.mime.multipart.MIMEMultipart()
    msg['From'] = PUBLIC_EMAIL
    msg['To'] = recipient
    msg['Subject'] = subject
    if reply_to:
        msg['Reply-To'] = reply_to

    msg.attach(email.mime.text.MIMEText(body, 'plain'))

    for key in attachment_keys:
        filename = key.split('/')[-1]
        lower = filename.lower()

        try:
            obj = s3.get_object(Bucket=BUCKET_NAME, Key=key)
            data = obj['Body'].read()
        except Exception as e:
            logger.error("attachment_fetch_failed", extra={"key": key, "error": str(e)})
            continue

        if any(lower.endswith(ext) for ext in ICS_EXTENSIONS):
            part = email.mime.text.MIMEText(data.decode('utf-8', errors='replace'), 'calendar')
            part.add_header('Content-Disposition', 'attachment', filename=filename)
        else:
            mime_type, _ = mimetypes.guess_type(filename)
            maintype, subtype = (mime_type or 'application/octet-stream').split('/', 1)
            part = email.mime.application.MIMEApplication(data, Name=filename)
            part.add_header('Content-Disposition', 'attachment', filename=filename)

        msg.attach(part)

    return msg.as_bytes()


def send_with_retry(recipient, subject, body, reply_to, attachment_keys):
    raw = build_raw_message(recipient, subject, body, reply_to, attachment_keys)
    last_error = None

    for attempt, delay in enumerate(RETRY_DELAYS, start=1):
        if delay > 0:
            time.sleep(delay)
        try:
            ses.send_raw_email(
                Source=PUBLIC_EMAIL,
                Destinations=[recipient],
                RawMessage={'Data': raw}
            )
            logger.info("forward_sent", extra={
                "recipient": recipient,
                "subject": subject,
                "attachment_count": len(attachment_keys),
                "attempt": attempt
            })
            return
        except ses.exceptions.ClientError as e:
            error_code = e.response['Error']['Code']
            last_error = e
            logger.warning("forward_send_failed", extra={
                "recipient": recipient,
                "error_code": error_code,
                "attempt": attempt
            })
            if error_code not in RETRYABLE_ERRORS:
                break
        except Exception as e:
            last_error = e
            logger.warning("forward_send_failed", extra={
                "recipient": recipient,
                "error": str(e),
                "attempt": attempt
            })

    logger.error("forward_send_exhausted", extra={
        "recipient": recipient,
        "error": str(last_error),
        "attempts": len(RETRY_DELAYS)
    })
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="Forward Sender: Send Failed After Retries",
        Message=f"Failed to forward email to {recipient}: {last_error}"
    )
    raise last_error


def lambda_handler(event, context):
    for record in event['Records']:
        message = json.loads(record['body'])
        send_with_retry(
            recipient=message['recipient'],
            subject=message['subject'],
            body=message['body'],
            reply_to=message.get('reply_to'),
            attachment_keys=message.get('attachment_keys', [])
        )
