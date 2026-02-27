# Resource Tagging

## Standard Tags

All resources receive the following tags via the `common_tags` variable, which is
constructed by the deploy script from `config.env` and values resolved at deploy time:

- **AccountId** - AWS account ID, resolved via `aws sts get-caller-identity`
- **AccountAlias** - AWS account alias, resolved via `aws iam list-account-aliases`
- **ContactEmail** - Public email address, configured as `CONTACT_EMAIL` in `config.env`
- **CostCenter** - Cost center, configured as `TAG_COST_CENTER` in `config.env`
- **DeployedBy** - ARN of the IAM principal that ran the deploy
- **Environment** - Deployment environment (e.g. `prd`), configured as `TAG_ENVIRONMENT`
- **LastDeployed** - ISO 8601 UTC timestamp of the most recent deploy
- **ManagedBy** - Always `Terraform`
- **Owner** - Owner name, configured as `TAG_OWNER` in `config.env`
- **ProjectName** - Derived from the git remote URL
- **ProjectRepository** - Full git remote URL
- **Region** - AWS region, configured as `AWS_REGION` in `config.env`

## Tag Usage

- **Cost allocation**: Filter AWS Cost Explorer by `ProjectName` or `CostCenter` to see
  per-project spend
- **Audit trail**: `DeployedBy` and `LastDeployed` identify who last changed the
  infrastructure and when
- **Resource discovery**: Filter resources by `Environment` or `ProjectName` in the AWS
  console or CLI to locate all project resources across services
