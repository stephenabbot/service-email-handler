import json
import os
import re
import boto3
from email import policy
from email.parser import BytesParser
from datetime import datetime
from mypylogger import get_logger

logger = get_logger(__name__)

s3 = boto3.client('s3')
sqs = boto3.client('sqs')
dynamodb = boto3.resource('dynamodb')
sns = boto3.client('sns')

BUCKET_NAME = os.environ['BUCKET_NAME']
TABLE_NAME = os.environ['TABLE_NAME']
PUBLIC_EMAIL = os.environ['PUBLIC_EMAIL']
SNS_TOPIC_ARN = os.environ['SNS_TOPIC_ARN']
REPLY_QUEUE_URL = os.environ['REPLY_QUEUE_URL']


def lookup_sender_email(conversation_id):
    table = dynamodb.Table(TABLE_NAME)
    try:
        response = table.get_item(Key={'conversationId': conversation_id})
        item = response.get('Item')
        if item and 'senderEmail' in item:
            return item['senderEmail']
        return None
    except Exception as e:
        logger.error("sender_lookup_failed", extra={
            "error": str(e),
            "conversation_id": conversation_id
        })
        return None


def extract_metadata_commands(body):
    metadata = {}
    pattern = r'\[(\w+):\s*([^\]]+)\]'
    matches = re.findall(pattern, body)

    for key, value in matches:
        key_lower = key.lower()
        if key_lower == 'company':
            metadata['companyName'] = value.strip()
        elif key_lower == 'title':
            metadata['title'] = value.strip()
        elif key_lower == 'type':
            metadata['type'] = value.strip()
        elif key_lower == 'location':
            metadata['location'] = value.strip()
        elif key_lower == 'salary_range':
            metadata['salaryRange'] = value.strip()
        elif key_lower == 'job_id':
            metadata['jobId'] = value.strip()
        elif key_lower == 'notes':
            metadata['notes'] = value.strip()

    return metadata

def clean_reply_body(body):
    # Strip everything from the METADATA marker onward (includes forwarded footer)
    metadata_marker = '--- METADATA ---'
    if metadata_marker in body:
        body = body.split(metadata_marker)[0]

    # Strip quoted lines (lines starting with >) that email clients insert
    lines = body.splitlines()
    cleaned = [line for line in lines if not line.startswith('>')]

    return '\n'.join(cleaned).strip()

def update_conversation_metadata(conversation_id, metadata):
    if not metadata:
        return

    # Table has only conversationId as hash key (no sort key), so update_item works correctly.
    table = dynamodb.Table(TABLE_NAME)

    try:
        update_expr = 'SET '
        expr_values = {}
        expr_names = {}

        for i, (key, value) in enumerate(metadata.items()):
            attr_name = f"#attr{i}"
            attr_value = f":val{i}"
            update_expr += f"{attr_name} = {attr_value}, "
            expr_names[attr_name] = key
            expr_values[attr_value] = value

        update_expr = update_expr.rstrip(', ')

        table.update_item(
            Key={'conversationId': conversation_id},
            UpdateExpression=update_expr,
            ExpressionAttributeNames=expr_names,
            ExpressionAttributeValues=expr_values
        )
        logger.info("metadata_updated", extra={"conversation_id": conversation_id, "metadata": metadata})
    except Exception as e:
        logger.error("metadata_update_failed", extra={"error": str(e), "conversation_id": conversation_id})
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="Reply Handler: Metadata Update Failed",
            Message=f"Failed to update metadata for {conversation_id}: {str(e)}"
        )

def lambda_handler(event, context):
    try:
        ses_record = event['Records'][0]['ses']
        mail = ses_record['mail']
        message_id = mail['messageId']

        recipient = mail['destination'][0]
        conversation_id = recipient.split('@')[0]

        original_sender = lookup_sender_email(conversation_id)

        if not original_sender:
            logger.error("sender_not_found", extra={
                "conversation_id": conversation_id,
                "thread_address": recipient
            })
            sns.publish(
                TopicArn=SNS_TOPIC_ARN,
                Subject="Reply Handler: Sender Not Found",
                Message=f"No senderEmail found for conversationId '{conversation_id}'. Manual cleanup required."
            )
            return

        # SES stores incoming mail to staging/; read from there
        staging_key = f"staging/{message_id}"
        obj = s3.get_object(Bucket=BUCKET_NAME, Key=staging_key)
        raw_email = obj['Body'].read()

        msg = BytesParser(policy=policy.default).parsebytes(raw_email)
        subject = msg['subject'] or 'Re: Your message'
        body = msg.get_body(preferencelist=('plain',))
        body_text = body.get_content() if body else ''

        logger.info("reply_received", extra={
            "conversation_id": conversation_id,
            "recipient": original_sender,
            "subject": subject,
            "body_preview": body_text[:500]
        })

        metadata = extract_metadata_commands(body_text)
        clean_body = clean_reply_body(body_text)

        update_conversation_metadata(conversation_id, metadata)

        sqs.send_message(
            QueueUrl=REPLY_QUEUE_URL,
            MessageBody=json.dumps({
                'recipient': original_sender,
                'subject': subject,
                'body': clean_body
            })
        )

        logger.info("reply_enqueued", extra={
            "conversation_id": conversation_id,
            "recipient": original_sender
        })

        # Archive reply email then clean up staging
        reply_key = f"conversations/{conversation_id}/{message_id}"
        s3.put_object(Bucket=BUCKET_NAME, Key=reply_key, Body=raw_email)
        s3.delete_object(Bucket=BUCKET_NAME, Key=staging_key)

    except Exception as e:
        logger.error("handler_failed", extra={"error": str(e)})
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="Reply Handler: Unhandled Exception",
            Message=f"Unhandled exception: {str(e)}"
        )
        raise
