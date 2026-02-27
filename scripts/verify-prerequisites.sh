#!/usr/bin/env bash
set -euo pipefail

# Accept optional argument to skip Podman check
SKIP_PODMAN="${1:-false}"

echo "Verifying prerequisites..."

# Detect Terraform-compatible tool (prefer OpenTofu)
if command -v tofu &> /dev/null; then
    TF_CMD="tofu"
elif command -v terraform &> /dev/null; then
    TF_CMD="terraform"
else
    echo "ERROR: Neither OpenTofu (tofu) nor Terraform found. Install one of them."
    exit 1
fi

echo "✓ Using $TF_CMD"

# Check for required tools
REQUIRED_TOOLS=("aws" "uv")
if [[ "$SKIP_PODMAN" != "true" ]]; then
    REQUIRED_TOOLS+=("podman")
fi
MISSING_TOOLS=()

for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [ ${#MISSING_TOOLS[@]} -ne 0 ]; then
    echo "ERROR: Missing required tools: ${MISSING_TOOLS[*]}"
    exit 1
fi

echo "✓ All required tools found"

# Check Podman is running (only if not skipped)
if [[ "$SKIP_PODMAN" != "true" ]]; then
    if ! podman ps &> /dev/null; then
        echo "⚠ WARNING: Podman is not running"
        echo "  Deploy script will attempt to start it automatically"
    else
        echo "✓ Podman is running"
    fi
fi

# Check AWS authentication
if ! aws sts get-caller-identity &> /dev/null; then
    echo "ERROR: AWS authentication failed. Please configure AWS credentials."
    exit 1
fi

echo "✓ AWS authentication successful"

# Check config.env exists
if [ ! -f "config.env" ]; then
    echo "ERROR: config.env not found in project root"
    exit 1
fi

echo "✓ config.env found"

echo "All prerequisites verified successfully!"
