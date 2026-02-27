import json
import os
import boto3
from pypdf import PdfReader
from docx import Document
from io import BytesIO
from mypylogger import get_logger

logger = get_logger(__name__)

s3 = boto3.client('s3')

def extract_text_from_pdf(file_bytes):
    try:
        pdf = PdfReader(BytesIO(file_bytes))
        text = ''
        for page in pdf.pages:
            text += page.extract_text()
        return text
    except Exception as e:
        logger.error("pdf_extraction_failed", extra={"error": str(e)})
        return None

def extract_text_from_docx(file_bytes):
    try:
        doc = Document(BytesIO(file_bytes))
        text = '\n'.join([para.text for para in doc.paragraphs])
        return text
    except Exception as e:
        logger.error("docx_extraction_failed", extra={"error": str(e)})
        return None

def lambda_handler(event, context):
    for record in event['Records']:
        bucket = record['s3']['bucket']['name']
        key = record['s3']['object']['key']
        
        if not key.startswith('attachments/'):
            continue
        
        try:
            obj = s3.get_object(Bucket=bucket, Key=key)
            file_bytes = obj['Body'].read()
            
            text = None
            if key.endswith('.pdf'):
                text = extract_text_from_pdf(file_bytes)
            elif key.endswith('.docx'):
                text = extract_text_from_docx(file_bytes)
            
            if text:
                text_key = key.replace('attachments/', 'extracted-text/') + '.txt'
                s3.put_object(Bucket=bucket, Key=text_key, Body=text.encode('utf-8'))
                logger.info("text_extracted", extra={"source_key": key, "text_key": text_key})
            else:
                logger.info("no_text_extracted", extra={"key": key})
                
        except Exception as e:
            logger.error("extraction_handler_failed", extra={"error": str(e), "key": key})
            raise
