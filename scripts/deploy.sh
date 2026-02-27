#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

# Verify prerequisites first
echo "Running prerequisite checks..."
"$SCRIPT_DIR/verify-prerequisites.sh"
echo ""

# Load configuration early (needed for deployment state check)
source config.env

# Check deployment state
echo "Checking deployment state..."

# Check core resources (suppress errors if resources don't exist)
HOSTED_ZONE_ID=$(aws ssm get-parameter --name "/static-website/infrastructure/${DOMAIN_NAME}/hosted-zone-id" --query 'Parameter.Value' --output text 2>/dev/null || echo "")

if [ -n "$HOSTED_ZONE_ID" ]; then
    MX_RECORDS=$(aws route53 list-resource-record-sets \
        --hosted-zone-id "$HOSTED_ZONE_ID" \
        --query "ResourceRecordSets[?Type=='MX' && (Name=='${DOMAIN_NAME}.' || Name=='thread.${DOMAIN_NAME}.')].Name" \
        --output text 2>/dev/null || echo "")
else
    MX_RECORDS=""
fi

SES_DOMAIN=$(aws ses list-identities --query "Identities[?contains(@, '${DOMAIN_NAME}')]" --output text 2>/dev/null || echo "")

SES_RULE_SETS=$(aws ses list-receipt-rule-sets --query "RuleSets[?Name=='service-email-handler-${TAG_ENVIRONMENT}-rules'].Name" --output text 2>/dev/null || echo "")

LAMBDA_FUNCTIONS=$(aws lambda list-functions --query "Functions[?starts_with(FunctionName, 'service-email-handler-${TAG_ENVIRONMENT}')].FunctionName" --output text 2>/dev/null || echo "")

# Count what exists
RESOURCE_COUNT=0
[ -n "$MX_RECORDS" ] && RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
[ -n "$SES_DOMAIN" ] && RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
[ -n "$SES_RULE_SETS" ] && RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
[ -n "$LAMBDA_FUNCTIONS" ] && RESOURCE_COUNT=$((RESOURCE_COUNT + 1))

# If some but not all core resources exist, it's a partial deployment
if [ $RESOURCE_COUNT -gt 0 ] && [ $RESOURCE_COUNT -lt 4 ]; then
    echo ""
    echo "ERROR: Partial deployment detected ($RESOURCE_COUNT/4 core resources exist)"
    echo "Please run './scripts/destroy.sh' to clean up before deploying."
    exit 1
elif [ $RESOURCE_COUNT -eq 4 ]; then
    echo "✓ Full deployment detected - will update existing resources"
else
    echo "✓ No existing deployment - will create new resources"
fi
echo ""

# Ensure Podman is running
echo "Checking Podman status..."
if ! podman ps &> /dev/null; then
    echo "Podman is not running. Attempting to start..."
    if podman machine start; then
        echo "✓ Podman started successfully"
    else
        echo "ERROR: Failed to start Podman"
        exit 1
    fi
else
    echo "✓ Podman is already running"
fi
echo ""

# Detect Terraform-compatible tool
if command -v tofu &> /dev/null; then
    TF_CMD="tofu"
elif command -v terraform &> /dev/null; then
    TF_CMD="terraform"
else
    echo "ERROR: Neither OpenTofu nor Terraform found"
    exit 1
fi

# Compute dynamic tags
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
ACCOUNT_ALIAS=$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null || echo "")
DEPLOYED_BY=$(aws sts get-caller-identity --query 'Arn' --output text)
LAST_DEPLOYED=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
PROJECT_NAME=$(git remote get-url origin | sed 's/.*\///' | sed 's/\.git$//')
PROJECT_REPOSITORY=$(git remote get-url origin)

# Get backend configuration from SSM
STATE_BUCKET=$(aws ssm get-parameter --name /terraform/foundation/s3-state-bucket --query 'Parameter.Value' --output text)
LOCK_TABLE=$(aws ssm get-parameter --name /terraform/foundation/dynamodb-lock-table --query 'Parameter.Value' --output text)

echo "Building Lambda functions..."

# Build each Lambda function
for lambda_dir in lambda/*/; do
    lambda_name=$(basename "$lambda_dir")
    echo "Building $lambda_name..."
    
    cd "$lambda_dir"
    
    # Create deployment package
    mkdir -p package
    
    # Install dependencies using podman
    if [ -f requirements.txt ]; then
        podman run --rm \
            --platform linux/amd64 \
            -v "$(pwd)":/workspace \
            -w /workspace \
            python:3.12-slim \
            bash -c "pip install uv && uv pip install --system -r requirements.txt --target package/ && cp handler.py package/"
    else
        cp handler.py package/
    fi
    
    # Copy template if exists (for inbound-handler)
    if [ -f "$PROJECT_ROOT/templates/auto-acknowledgement.txt" ] && [ "$lambda_name" = "inbound-handler" ]; then
        cp "$PROJECT_ROOT/templates/auto-acknowledgement.txt" package/
    fi
    
    # Create zip
    cd package
    zip -r ../deployment.zip . > /dev/null
    cd ..
    
    # Cleanup
    rm -rf package
    
    cd "$PROJECT_ROOT"
done

echo "Uploading Lambda packages to S3..."
DEPLOYMENT_BUCKET="${PROJECT_NAME}-${ACCOUNT_ID}-${AWS_REGION}"

# Check if bucket exists
if aws s3 ls "s3://${DEPLOYMENT_BUCKET}" 2>/dev/null; then
    echo "Bucket already exists, will import into Terraform state if needed"
else
    echo "Bucket does not exist, Terraform will create it"
fi

# Upload Lambda packages (bucket will be created by Terraform if needed)
for lambda_dir in lambda/*/; do
    lambda_name=$(basename "$lambda_dir")
    # Try to upload, if bucket doesn't exist yet, skip (Terraform will create it)
    if aws s3 ls "s3://${DEPLOYMENT_BUCKET}" 2>/dev/null; then
        aws s3 cp "${lambda_dir}deployment.zip" "s3://${DEPLOYMENT_BUCKET}/deployments/${lambda_name}.zip"
    fi
done

echo "Initializing $TF_CMD..."

# Initialize Terraform with backend config
$TF_CMD init \
    -backend-config="bucket=${STATE_BUCKET}" \
    -backend-config="key=${PROJECT_NAME}/terraform.tfstate" \
    -backend-config="region=${AWS_REGION}" \
    -backend-config="dynamodb_table=${LOCK_TABLE}"

# Import existing bucket if it exists and not in state
if aws s3 ls "s3://${DEPLOYMENT_BUCKET}" 2>/dev/null; then
    if ! $TF_CMD state show module.s3_buckets.aws_s3_bucket.email_storage 2>/dev/null; then
        echo "Importing existing S3 bucket into Terraform state..."
        $TF_CMD import module.s3_buckets.aws_s3_bucket.email_storage "${DEPLOYMENT_BUCKET}" || true
    fi
fi

echo "Deploying infrastructure..."

# Create tfvars
cat > terraform.tfvars <<EOF
aws_region    = "${AWS_REGION}"
project_name  = "${PROJECT_NAME}"
environment   = "${TAG_ENVIRONMENT}"
public_email  = "${CONTACT_EMAIL}"
private_email = "${PRIVATE_EMAIL}"
domain_name   = "${DOMAIN_NAME}"
alert_email   = "${PRIVATE_EMAIL}"

common_tags = {
  AccountId         = "${ACCOUNT_ID}"
  AccountAlias      = "${ACCOUNT_ALIAS}"
  ContactEmail      = "${CONTACT_EMAIL}"
  CostCenter        = "${TAG_COST_CENTER}"
  DeployedBy        = "${DEPLOYED_BY}"
  Environment       = "${TAG_ENVIRONMENT}"
  LastDeployed      = "${LAST_DEPLOYED}"
  ManagedBy         = "Terraform"
  Owner             = "${TAG_OWNER}"
  ProjectName       = "${PROJECT_NAME}"
  ProjectRepository = "${PROJECT_REPOSITORY}"
  Region            = "${AWS_REGION}"
}
EOF

# Apply Terraform
$TF_CMD apply -auto-approve

# Upload Lambda packages after bucket is created
echo "Uploading Lambda packages..."
for lambda_dir in lambda/*/; do
    lambda_name=$(basename "$lambda_dir")
    aws s3 cp "${lambda_dir}deployment.zip" "s3://${DEPLOYMENT_BUCKET}/deployments/${lambda_name}.zip"
done

# Deploy spam filter configuration
echo "Deploying spam filter configuration..."
"${SCRIPT_DIR}/deploy_spam_filter.sh"

echo "Deployment complete!"
echo ""
echo "IMPORTANT: Check your email to confirm SNS subscription for CloudWatch alarms."
