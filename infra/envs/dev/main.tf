provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project = "rag-insurellm"
      env     = "dev"
      managed = "terraform"
    }
  }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/rag-insurellm/dev/app"
  retention_in_days = 14
}
