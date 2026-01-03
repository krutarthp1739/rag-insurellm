variable "tf_state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state"
  type        = string
}

variable "region" {
  description = "AWS region for bootstrap resources"
  type        = string
  default     = "us-east-1"
}

variable "github_org" {
  description = "GitHub organization/user for OIDC trust"
  type        = string
  default     = "krutarthpatel"
}

variable "github_repo" {
  description = "GitHub repository name for OIDC trust"
  type        = string
  default     = "rag-insurellm"
}
