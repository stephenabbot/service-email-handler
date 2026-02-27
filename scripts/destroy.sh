#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

# Verify prerequisites first (AWS auth needed for destroy)
echo "Running prerequisite checks..."
"$SCRIPT_DIR/verify-prerequisites.sh" true
echo ""

# Load config
if [[ ! -f config.env ]]; then
    echo "Error: config.env not found"
    exit 1
fi
source config.env

# Detect Terraform-compatible tool
if command -v tofu &> /dev/null; then
    TF_CMD="tofu"
elif command -v terraform &> /dev/null; then
    TF_CMD="terraform"
else
    echo "ERROR: Neither OpenTofu nor Terraform found"
    exit 1
fi

echo "Destroying infrastructure..."
echo ""

# Clean up partially deployed resources first
echo "Checking for partially deployed resources..."

# Deactivate SES receipt rule set if active
ACTIVE_RULESET=$(aws ses describe-active-receipt-rule-set --region "$AWS_REGION" \
    --query "Metadata.Name" --output text 2>/dev/null || echo "")
if [[ -n "$ACTIVE_RULESET" && "$ACTIVE_RULESET" != "None" ]]; then
    echo "  Deactivating SES receipt rule set: $ACTIVE_RULESET"
    aws ses set-active-receipt-rule-set --region "$AWS_REGION" 2>/dev/null || true
fi

# Delete SES receipt rule sets
RULE_SETS=$(aws ses list-receipt-rule-sets --region "$AWS_REGION" \
    --query "RuleSets[?contains(Name, 'service-email-handler')].Name" \
    --output text 2>/dev/null || echo "")
for ruleset in $RULE_SETS; do
    echo "  Deleting SES receipt rule set: $ruleset"
    aws ses delete-receipt-rule-set --rule-set-name "$ruleset" --region "$AWS_REGION" 2>/dev/null || true
done

# Empty and delete S3 bucket if it exists
BUCKET_NAME="${TAG_ENVIRONMENT}-email-handler-${DOMAIN_NAME//./-}"
if aws s3 ls "s3://$BUCKET_NAME" &> /dev/null 2>&1; then
    echo "  Emptying S3 bucket: $BUCKET_NAME"
    aws s3 rm "s3://$BUCKET_NAME" --recursive --region "$AWS_REGION" 2>/dev/null || true
fi

# Delete Lambda functions
LAMBDA_FUNCTIONS=$(aws lambda list-functions --region "$AWS_REGION" \
    --query "Functions[?contains(FunctionName, 'email-handler')].FunctionName" \
    --output text 2>/dev/null || echo "")
for func in $LAMBDA_FUNCTIONS; do
    echo "  Deleting Lambda function: $func"
    aws lambda delete-function --function-name "$func" --region "$AWS_REGION" 2>/dev/null || true
done

echo ""

# Run Terraform destroy
if $TF_CMD state list &> /dev/null 2>&1; then
    echo "Running Terraform destroy..."
    $TF_CMD destroy -auto-approve
else
    echo "No Terraform state found, skipping Terraform destroy"
fi

echo ""
echo "Infrastructure destroyed successfully!"
