# rag-insurellm

## Phase A: Serverless Terraform + GitHub Actions bootstrap
This phase wires up Terraform state, GitHub OIDC for AWS, and CI/CD for the dev serverless stack (no VPC yet).

### Prerequisites
- AWS CLI configured to the target account (`aws sts get-caller-identity` should work).
- Terraform >= 1.6 installed locally.

### Bootstrap (one-time, local)
1. Set a globally unique bucket name for state (example: `rag-insurellm-tf-state-<unique>`).
2. `cd infra/bootstrap`
3. `terraform init`
4. `terraform apply -var tf_state_bucket_name=<your-unique-bucket> [-var region=us-east-1 -var github_org=krutarthpatel -var github_repo=rag-insurellm]`
5. Note the outputs: `tf_state_bucket`, `tf_lock_table`, `gha_role_arn`, and `account_id`.

### Wire dev backend to the new state bucket
1. Edit `infra/envs/dev/versions.tf` and replace `REPLACE_ME_TF_STATE_BUCKET` with the `tf_state_bucket` output from bootstrap.
2. Commit the change so CI/CD uses the correct backend.

### GitHub secret for deploys
1. Go to GitHub repo Settings → Secrets and variables → Actions.
2. Create secret `AWS_ROLE_ARN` with the `gha_role_arn` output from bootstrap.

### Workflows and deploy
- `CI` workflow (`.github/workflows/ci.yml`) runs on push/PR: `terraform fmt -check`, `terraform init -backend=false`, and `terraform validate` in `infra/envs/dev`.
- `Deploy Dev` workflow (`.github/workflows/deploy-dev.yml`) runs on push to `main` or manual dispatch. It assumes `AWS_ROLE_ARN`, runs `terraform init/plan/apply` in `infra/envs/dev`, and deploys to dev.
- To trigger deploy: push to `main` or use “Run workflow” in Actions.

### Confirm success
- After deploy, confirm CloudWatch log group exists: `/rag-insurellm/dev/app` (e.g., `aws logs describe-log-groups --log-group-name-prefix /rag-insurellm/dev/app --region us-east-1`).

### What we built in Phase A
- Versioned, encrypted S3 bucket + DynamoDB lock table for Terraform remote state.
- GitHub OIDC provider and `rag-insurellm-gha-terraform-dev` IAM role scoped to `krutarthpatel/rag-insurellm` refs, temporarily with `AdministratorAccess`.
- Dev Terraform stack with default tags and a sample CloudWatch log group to validate apply.
- CI (fmt/validate) and deploy-to-dev GitHub Actions workflows.

## Phase B1: Markdown ingestion pipeline (dev)
This phase ingests Markdown files dropped in S3, chunks them, embeds with Bedrock Titan, writes vectors (placeholder for S3 Vectors), and stores an auditable manifest.

### Bedrock access
- Enable access to the Titan Embeddings model (default `amazon.titan-embed-text-v2:0`) in us-east-1 for the AWS account used by the deploy role. No secrets are required; the Lambda uses OIDC-assumed role permissions.

### Deploy
- The deploy-dev workflow already applies `infra/envs/dev`; push to `main` or trigger manually.

### Buckets and queues (dev)
- Raw uploads bucket: `rag-insurellm-dev-raw-<account_id>` (S3-created). Upload `.md` files here.
- Processed bucket: `rag-insurellm-dev-processed-<account_id>` holds manifests and placeholder vector artifacts.
- SQS: `rag-insurellm-dev-ingest-queue` with DLQ `rag-insurellm-dev-ingest-dlq`.
- Lambda: `rag-insurellm-dev-ingest` processes SQS events, invokes Titan embeddings, and writes manifests to `processed/{doc_id}/chunks.json` in the processed bucket.
- CloudWatch logs: `/aws/lambda/rag-insurellm-dev-ingest` (14-day retention).

### S3 Vectors placeholder
- Terraform includes a `null_resource` placeholder for the S3 Vectors index `rag-insurellm-dev-kb` (namespace `default`) until native provider support is available.
- Lambda currently writes per-chunk vector payloads (including embeddings) to the processed bucket under `vectors/<index>/<namespace>/` for auditability. Swap this to a real S3 Vectors upsert call when supported.

### Validate the pipeline
1) Upload a Markdown file (suffix `.md`) to the raw bucket.
2) Watch CloudWatch logs for `rag-insurellm-dev-ingest` to confirm chunking/embedding.
3) Check the processed bucket for `processed/{doc_id}/chunks.json` and the `vectors/` folder. `doc_id` is `sha256(bucket:key:version_id|etag)` so reprocessing the same object overwrites in-place.

### Exit criteria
- Terraform bootstrap applied once locally with unique state bucket.
- `infra/envs/dev/versions.tf` updated with the real state bucket name.
- GitHub secret `AWS_ROLE_ARN` set to the bootstrap output.
- CI green on PRs; deploy workflow succeeds from `main` and creates the dev log group.
