#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

# Load config
if [[ ! -f config.env ]]; then
    echo "Error: config.env not found"
    exit 1
fi
source config.env

echo "Deployed Resources"
echo "=================="
echo ""

# Check Terraform state
TERRAFORM_CMD="terraform"
if command -v tofu &> /dev/null; then
    TERRAFORM_CMD="tofu"
fi

if $TERRAFORM_CMD state list &> /dev/null 2>&1; then
    echo "Terraform-Managed Resources:"
    echo "----------------------------"
    $TERRAFORM_CMD state list | while read -r resource; do
        resource_type=$(echo "$resource" | cut -d'.' -f1)
        resource_name=$(echo "$resource" | cut -d'.' -f2-)
        printf "  %-40s %s\n" "$resource_type" "$resource_name"
    done | sort
    echo ""
fi

# Check for partially deployed resources
echo "Checking for Partially Deployed Resources:"
echo "-------------------------------------------"

# Check Route 53 MX records
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones --query "HostedZones[?Name=='${DOMAIN_NAME}.'].Id" --output text 2>/dev/null | cut -d'/' -f3 || echo "")
if [[ -n "$HOSTED_ZONE_ID" ]]; then
    MX_RECORDS=$(aws route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
        --query "ResourceRecordSets[?Type=='MX' && (Name=='${DOMAIN_NAME}.' || Name=='thread.${DOMAIN_NAME}.')].Name" \
        --output text 2>/dev/null || echo "")
    if [[ -n "$MX_RECORDS" ]]; then
        echo "  ✓ Route53 MX records found:"
        for record in $MX_RECORDS; do
            echo "    - $record"
        done
    fi
fi

# Check SES domain verification
SES_DOMAIN=$(aws ses get-identity-verification-attributes --identities "$DOMAIN_NAME" \
    --region "$AWS_REGION" \
    --query "VerificationAttributes.\"${DOMAIN_NAME}\".VerificationStatus" \
    --output text 2>/dev/null || echo "")
if [[ "$SES_DOMAIN" == "Success" ]]; then
    echo "  ✓ SES domain verified: $DOMAIN_NAME"
fi

# Check SES receipt rule sets
PROJECT_PREFIX="${TAG_ENVIRONMENT}-email-handler"
RULE_SETS=$(aws ses list-receipt-rule-sets --region "$AWS_REGION" \
    --query "RuleSets[?contains(Name, 'service-email-handler')].Name" \
    --output text 2>/dev/null || echo "")
if [[ -n "$RULE_SETS" ]]; then
    echo "  ✓ SES receipt rule sets found:"
    for ruleset in $RULE_SETS; do
        ACTIVE=$(aws ses describe-active-receipt-rule-set --region "$AWS_REGION" \
            --query "Metadata.Name" --output text 2>/dev/null || echo "")
        if [[ "$ACTIVE" == "$ruleset" ]]; then
            echo "    - $ruleset (ACTIVE)"
        else
            echo "    - $ruleset"
        fi
    done
fi

# Check S3 buckets
BUCKET_NAME="${TAG_ENVIRONMENT}-email-handler-${DOMAIN_NAME//./-}"
if aws s3 ls "s3://$BUCKET_NAME" &> /dev/null 2>&1; then
    echo "  ✓ S3 bucket exists: $BUCKET_NAME"
fi

# Check DynamoDB tables
TABLE_NAME="${TAG_ENVIRONMENT}-email-handler-conversations"
if aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$AWS_REGION" &> /dev/null 2>&1; then
    echo "  ✓ DynamoDB table exists: $TABLE_NAME"
fi

# Check Lambda functions
LAMBDA_FUNCTIONS=$(aws lambda list-functions --region "$AWS_REGION" \
    --query "Functions[?contains(FunctionName, 'email-handler')].FunctionName" \
    --output text 2>/dev/null || echo "")
if [[ -n "$LAMBDA_FUNCTIONS" ]]; then
    echo "  ✓ Lambda functions found:"
    for func in $LAMBDA_FUNCTIONS; do
        echo "    - $func"
    done
fi

echo ""
echo "Note: Resources listed above may be partially deployed if previous deployment failed."
