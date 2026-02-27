import json
import os
import time
import boto3
from mypylogger import get_logger

logger = get_logger(__name__)

ses = boto3.client('ses')
sns = boto3.client('sns')

PUBLIC_EMAIL = os.environ['PUBLIC_EMAIL']
SNS_TOPIC_ARN = os.environ['SNS_TOPIC_ARN']

RETRY_DELAYS = [0, 5, 30, 120]
RETRYABLE_ERRORS = {'MailFromDomainNotVerifiedException', 'Throttling', 'ServiceUnavailable'}


def send_with_retry(recipient, subject, body, reply_to=None):
    last_error = None
    kwargs = {
        'Source': PUBLIC_EMAIL,
        'Destination': {'ToAddresses': [recipient]},
        'Message': {
            'Subject': {'Data': subject},
            'Body': {'Text': {'Data': body}}
        }
    }
    if reply_to:
        kwargs['ReplyToAddresses'] = [reply_to]

    for attempt, delay in enumerate(RETRY_DELAYS, start=1):
        if delay > 0:
            time.sleep(delay)
        try:
            ses.send_email(**kwargs)
            logger.info("forward_sent", extra={
                "recipient": recipient,
                "subject": subject,
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
            reply_to=message.get('reply_to')
        )
