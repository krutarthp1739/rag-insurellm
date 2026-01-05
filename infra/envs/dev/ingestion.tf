data "aws_caller_identity" "current" {}

locals {
  account_id            = data.aws_caller_identity.current.account_id
  raw_bucket_name       = "rag-insurellm-dev-raw-${local.account_id}"
  processed_bucket_name = "rag-insurellm-dev-processed-${local.account_id}"
  ingest_queue_name     = "rag-insurellm-dev-ingest-queue"
  ingest_dlq_name       = "rag-insurellm-dev-ingest-dlq"
  ingest_lambda_name    = "rag-insurellm-dev-ingest"
  s3_vectors_index_name = "rag-insurellm-dev-kb"
  s3_vectors_namespace  = "default"
  embedding_model_id    = "amazon.titan-embed-text-v2:0"
}

resource "aws_s3_bucket" "raw" {
  bucket = local.raw_bucket_name
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "raw" {
  bucket = aws_s3_bucket.raw.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "processed" {
  bucket = local.processed_bucket_name
}

resource "aws_s3_bucket_server_side_encryption_configuration" "processed" {
  bucket = aws_s3_bucket.processed.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "processed" {
  bucket = aws_s3_bucket.processed.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_sqs_queue" "ingest_dlq" {
  name = local.ingest_dlq_name
}

resource "aws_sqs_queue" "ingest_queue" {
  name                       = local.ingest_queue_name
  visibility_timeout_seconds = 60
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ingest_dlq.arn
    maxReceiveCount     = 5
  })
}

data "aws_iam_policy_document" "ingest_queue_policy" {
  statement {
    sid     = "AllowS3SendMessage"
    effect  = "Allow"
    actions = ["sqs:SendMessage"]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    resources = [aws_sqs_queue.ingest_queue.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.raw.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sqs_queue_policy" "ingest_queue" {
  queue_url = aws_sqs_queue.ingest_queue.id
  policy    = data.aws_iam_policy_document.ingest_queue_policy.json
}

resource "aws_s3_bucket_notification" "raw_to_sqs" {
  bucket = aws_s3_bucket.raw.id

  queue {
    queue_arn     = aws_sqs_queue.ingest_queue.arn
    events        = ["s3:ObjectCreated:*"]
    filter_suffix = ".md"
  }

  depends_on = [aws_sqs_queue_policy.ingest_queue]
}

data "archive_file" "ingest_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../../../services/ingestion"
  output_path = "${path.module}/build/ingest.zip"
}

data "aws_iam_policy_document" "ingest_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ingest_lambda" {
  name               = "${local.ingest_lambda_name}-role"
  assume_role_policy = data.aws_iam_policy_document.ingest_assume_role.json
}

data "aws_iam_policy_document" "ingest_permissions" {
  statement {
    sid    = "AllowLogging"
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["arn:aws:logs:*:*:*"]
  }

  statement {
    sid    = "AllowSQSProcessing"
    effect = "Allow"

    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ChangeMessageVisibility",
    ]

    resources = [aws_sqs_queue.ingest_queue.arn]
  }

  statement {
    sid    = "AllowRawRead"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]

    resources = [
      "${aws_s3_bucket.raw.arn}/*",
    ]
  }

  statement {
    sid    = "AllowProcessedWrite"
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:PutObjectAcl",
    ]

    resources = [
      "${aws_s3_bucket.processed.arn}/*",
    ]
  }

  statement {
    sid    = "AllowBedrockEmbeddings"
    effect = "Allow"

    actions = [
      "bedrock:InvokeModel",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "ingest_permissions" {
  name   = "${local.ingest_lambda_name}-policy"
  policy = data.aws_iam_policy_document.ingest_permissions.json
}

resource "aws_iam_role_policy_attachment" "ingest_permissions" {
  role       = aws_iam_role.ingest_lambda.name
  policy_arn = aws_iam_policy.ingest_permissions.arn
}

resource "aws_lambda_function" "ingest" {
  function_name = local.ingest_lambda_name
  role          = aws_iam_role.ingest_lambda.arn
  runtime       = "python3.11"
  handler       = "handler.lambda_handler"
  filename      = data.archive_file.ingest_lambda.output_path
  timeout       = 60
  memory_size   = 512

  source_code_hash = data.archive_file.ingest_lambda.output_base64sha256

  environment {
    variables = {
      RAW_BUCKET              = aws_s3_bucket.raw.bucket
      PROCESSED_BUCKET        = aws_s3_bucket.processed.bucket
      S3_VECTORS_INDEX        = local.s3_vectors_index_name
      S3_VECTORS_NAMESPACE    = local.s3_vectors_namespace
      BEDROCK_EMBEDDING_MODEL = local.embedding_model_id
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.ingest_permissions,
    aws_cloudwatch_log_group.ingest,
  ]
}

resource "aws_cloudwatch_log_group" "ingest" {
  name              = "/aws/lambda/${local.ingest_lambda_name}"
  retention_in_days = 14
}

resource "aws_lambda_event_source_mapping" "ingest_queue" {
  event_source_arn = aws_sqs_queue.ingest_queue.arn
  function_name    = aws_lambda_function.ingest.arn
  batch_size       = 5
  enabled          = true
}

resource "null_resource" "s3_vectors_index_placeholder" {
  triggers = {
    index_name = local.s3_vectors_index_name
    namespace  = local.s3_vectors_namespace
  }

  provisioner "local-exec" {
    command = "echo \"Placeholder: ensure S3 Vectors index ${self.triggers.index_name} (namespace ${self.triggers.namespace}) exists until native Terraform support is available.\""
  }
}
