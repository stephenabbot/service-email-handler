#!/bin/bash
# Deploy spam filter configuration to S3
# Can be run standalone or called by deploy.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load configuration
if [ -f "${PROJECT_ROOT}/config.env" ]; then
    source "${PROJECT_ROOT}/config.env"
else
    echo "Error: config.env not found"
    exit 1
fi

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="service-email-handler-${ACCOUNT_ID}-${AWS_REGION}"
S3_KEY="spam-filter/keywords.txt"
SOURCE_FILE="${PROJECT_ROOT}/spam-filter/keywords.txt"

# Temp dir mounted into the container; output file written there by the Python script.
TEMP_DIR=$(mktemp -d)
SCRIPT_FILE="${TEMP_DIR}/validate.py"
OUTPUT_FILE="${TEMP_DIR}/keywords_validated.txt"

echo "Deploying spam filter configuration..."

# Validate source file exists
if [ ! -f "${SOURCE_FILE}" ]; then
    echo "Error: ${SOURCE_FILE} not found"
    exit 1
fi

# Write the validation script to a temp file so it can be mounted into the container.
# Using podman (same image as Lambda builds) ensures pcre2 matches the Lambda runtime.
cat > "${SCRIPT_FILE}" << 'PYTHON_SCRIPT'
import pcre2
import sys

source_file = sys.argv[1]
output_file = sys.argv[2]

try:
    with open(source_file, 'r') as f:
        content = f.read()

    sections = {
        'blocked_sender_domains': [],
        'subject_patterns': [],
        'body_patterns': []
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
            try:
                pcre2.compile(line, pcre2.IGNORECASE)
            except Exception as e:
                print(f"Error: Invalid regex in {current_section}: {line}")
                print(f"  {e}")
                sys.exit(1)
            sections[current_section].append(line)

    # Alphabetize each section
    for key in sections:
        sections[key] = sorted(sections[key])

    with open(output_file, 'w') as f:
        f.write('--- BLOCKED_SENDER_DOMAINS ---\n')
        for pattern in sections['blocked_sender_domains']:
            f.write(f"{pattern}\n")
        f.write('\n--- SUBJECT_PATTERNS ---\n')
        for pattern in sections['subject_patterns']:
            f.write(f"{pattern}\n")
        f.write('\n--- BODY_PATTERNS ---\n')
        for pattern in sections['body_patterns']:
            f.write(f"{pattern}\n")

    print(f"Validated and alphabetized {len(sections['blocked_sender_domains'])} domain patterns")
    print(f"Validated and alphabetized {len(sections['subject_patterns'])} subject patterns")
    print(f"Validated and alphabetized {len(sections['body_patterns'])} body patterns")

except Exception as e:
    print(f"Error processing file: {e}")
    sys.exit(1)
PYTHON_SCRIPT

# Run validation inside podman using the same image as Lambda builds.
# /spam-filter → read-only source; /work → writable output dir.
podman run --rm \
    --platform linux/amd64 \
    -v "${PROJECT_ROOT}/spam-filter":/spam-filter:ro \
    -v "${TEMP_DIR}":/work \
    python:3.12-slim \
    bash -c "pip install pcre2 -q --root-user-action=ignore && python3 /work/validate.py /spam-filter/keywords.txt /work/keywords_validated.txt"

if [ $? -ne 0 ]; then
    rm -rf "${TEMP_DIR}"
    exit 1
fi

# Check if bucket exists
if ! aws s3 ls "s3://${BUCKET_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    echo "Error: S3 bucket ${BUCKET_NAME} does not exist"
    echo "Run ./scripts/deploy.sh first to create infrastructure"
    rm -rf "${TEMP_DIR}"
    exit 1
fi

# Upload validated file to S3
echo "Uploading to s3://${BUCKET_NAME}/${S3_KEY}..."
aws s3 cp "${OUTPUT_FILE}" "s3://${BUCKET_NAME}/${S3_KEY}" --region "${AWS_REGION}"

# Cleanup
rm -rf "${TEMP_DIR}"

echo "Spam filter configuration deployed successfully!"
echo "Lambda will pick up changes on next cold start (within ${SPAM_KEYWORDS_TTL:-300}s for warm containers)"
