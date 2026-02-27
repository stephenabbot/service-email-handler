# Prerequisites

## AWS

### Account Requirements

- **SES out of sandbox**: By default SES only sends to verified addresses. To send to any
  recipient, request production access in the AWS console under
  SES → Account dashboard → Request production access.
- **Route53 hosted zone**: A hosted zone for your domain must exist. The deploy script
  reads the hosted zone ID from SSM at
  `/static-website/infrastructure/{DOMAIN_NAME}/hosted-zone-id`.
- **Terraform backend**: The deploy script reads backend configuration from two SSM
  parameters:
  - `/terraform/foundation/s3-state-bucket` — S3 bucket for Terraform state
  - `/terraform/foundation/dynamodb-lock-table` — DynamoDB table for state locking

### IAM Permissions

The AWS principal used for deployment requires permissions to create and manage:
SES, Lambda, S3, DynamoDB, CloudWatch, SNS, Route53, SSM, and IAM roles.

### Region

All resources deploy to a single region. The default is `us-east-1`. SES inbound email
receiving is only available in supported regions: `us-east-1`, `us-west-2`, `eu-west-1`.

---

## Tools

### OpenTofu or Terraform

- **Version**: OpenTofu >= 1.0 or Terraform >= 1.0
- **Installation**: [opentofu.org](https://opentofu.org/docs/intro/install/) or
  [developer.hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install)
- The deploy script auto-detects which is installed, preferring OpenTofu

```bash
# Verify
tofu --version
# or
terraform --version
```

### AWS CLI

- **Version**: 2.x
- **Installation**: [aws.amazon.com/cli](https://aws.amazon.com/cli/)
- Must be authenticated before running any script

```bash
# Verify authentication
aws sts get-caller-identity

# Configure credentials (if needed)
aws configure
```

### Podman

- **Version**: Any recent version
- **Installation**: [podman.io](https://podman.io/docs/installation)
- Required for building Lambda packages. The deploy script auto-starts the Podman machine
  if it is not running.

**Critical on Apple Silicon**: All Lambda builds use `--platform linux/amd64`. Lambda runs
on x86_64. Native Python extensions (`pcre2`, `lxml`) compiled for arm64 will cause a
`Runtime.ImportModuleError` at runtime. See
[Troubleshooting](troubleshooting.md#lambda-importmoduleerror-at-runtime) if this occurs.

```bash
# Verify
podman --version

# Start machine (macOS)
podman machine start
```

### uv

- **Version**: Any recent version
- **Installation**: [docs.astral.sh/uv](https://docs.astral.sh/uv/getting-started/installation/)
- Used inside the Podman container to install Python dependencies into the Lambda package
  directory

```bash
# Verify
uv --version
```

---

## Domain Configuration

Your domain must meet the following conditions before deploying:

1. A Route53 hosted zone exists for the domain, and the hosted zone ID is stored in SSM
   at `/static-website/infrastructure/{DOMAIN_NAME}/hosted-zone-id`.
2. No conflicting MX records exist at the root domain — the deploy creates SES inbound MX
   records at `denverbytes.com` and `thread.denverbytes.com`.
3. Existing TXT records at the root domain are preserved. The SPF record managed by
   Terraform merges new values alongside any existing TXT records.

---

## SES Domain Verification

SES domain verification and DKIM verification are triggered by Terraform on the first
deploy. The three DKIM CNAME records are created by Terraform and verification completes
within minutes of DNS propagation.

If DKIM verification shows `Failed` despite correct DNS records (which can occur if
verification was triggered before the CNAMEs were in DNS), re-trigger it via
`z_runcommands.sh`:

```bash
aws ses verify-domain-dkim \
    --domain denverbytes.com >> z_command_outputs.txt
```

SES re-checks within minutes of the trigger.
