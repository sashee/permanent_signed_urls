provider "aws" {
}

# S3 bucket

resource "aws_s3_bucket" "bucket" {
  force_destroy = "true"
}

resource "aws_s3_bucket_object" "object" {
  for_each = toset(["tolstoy.pdf", "davinci.pdf"])

  key                 = each.value
  source              = "${path.module}/${each.value}"
  bucket              = aws_s3_bucket.bucket.bucket
  etag                = filemd5("${path.module}/${each.value}")
  content_disposition = "inline"
  content_type        = "application/pdf"
}

# DDB

resource "aws_dynamodb_table" "links-table" {
  name         = "links-${random_id.id.hex}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "Token"

  attribute {
    name = "Token"
    type = "S"
  }
}

# Lambda function

resource "random_id" "id" {
  byte_length = 8
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "/tmp/${random_id.id.hex}-lambda.zip"
  source {
    content  = file("index.js")
    filename = "index.js"
  }
  source {
    content  = file("index.html")
    filename = "index.html"
  }
}

resource "aws_lambda_function" "signer_lambda" {
  function_name = "signer-${random_id.id.hex}-function"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  handler = "index.handler"
  runtime = "nodejs12.x"
  role    = aws_iam_role.lambda_exec.arn
  environment {
    variables = {
      BUCKET = aws_s3_bucket.bucket.bucket
      TABLE  = aws_dynamodb_table.links-table.id
    }
  }
}

data "aws_iam_policy_document" "lambda_exec_role_policy" {
  statement {
    actions = [
      "s3:GetObject",
    ]
    resources = [
      "${aws_s3_bucket.bucket.arn}/*",
    ]
  }
  statement {
    actions = [
      "dynamodb:Scan",
      "dynamodb:PutItem",
      "dynamodb:GetItem",
      "dynamodb:DeleteItem",
    ]
    resources = [
      aws_dynamodb_table.links-table.arn,
    ]
  }
  statement {
    actions = [
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.bucket.arn,
    ]
  }
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:*:*:*"
    ]
  }
}

resource "aws_cloudwatch_log_group" "loggroup" {
  name              = "/aws/lambda/${aws_lambda_function.signer_lambda.function_name}"
  retention_in_days = 14
}

resource "aws_iam_role_policy" "lambda_exec_role" {
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.lambda_exec_role_policy.json
}

resource "aws_iam_role" "lambda_exec" {
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
	{
	  "Action": "sts:AssumeRole",
	  "Principal": {
		"Service": "lambda.amazonaws.com"
	  },
	  "Effect": "Allow"
	}
  ]
}
EOF
}

# API Gateway

resource "aws_apigatewayv2_api" "api" {
  name          = "signer-${random_id.id.hex}"
  protocol_type = "HTTP"
  target        = aws_lambda_function.signer_lambda.arn
}

resource "aws_lambda_permission" "apigw" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.signer_lambda.arn
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

output "url" {
  value = aws_apigatewayv2_api.api.api_endpoint
}
