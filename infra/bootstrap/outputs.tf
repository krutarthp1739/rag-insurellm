output "tf_state_bucket" {
  description = "Terraform state bucket name"
  value       = aws_s3_bucket.tf_state.bucket
}

output "tf_lock_table" {
  description = "Terraform lock table name"
  value       = aws_dynamodb_table.tf_lock.name
}

output "gha_role_arn" {
  description = "IAM role for GitHub Actions Terraform deploys (dev)"
  value       = aws_iam_role.gha_terraform_dev.arn
}

output "account_id" {
  description = "AWS account ID used for bootstrap"
  value       = data.aws_caller_identity.current.account_id
}
