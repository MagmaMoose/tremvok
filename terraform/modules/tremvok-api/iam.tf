# The function's role. Scoped to exactly the four things the code does: write and read its own
# table, read its own secrets, and write its own logs. Nothing here can spend money.

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name}-lambda"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid    = "OwnLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    # Scoped to this function's log group rather than "*". CreateLogGroup is absent because
    # Terraform creates the group with a retention policy — leaving the function to create it
    # on first use is how a log group ends up with `never expire` and a slow bill.
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }

  statement {
    sid    = "OwnTable"
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
    ]
    resources = [aws_dynamodb_table.deployments.arn]
  }

  statement {
    sid       = "OwnSecrets"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter${var.parameter_prefix}/*"]
  }

  statement {
    sid    = "DecryptOwnSecrets"
    effect = "Allow"
    # SecureString parameters are decrypted with the account's default SSM key. Without this
    # the GetParameter above succeeds and returns ciphertext, which reads as "the webhook is
    # not configured" rather than as a permissions error.
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${var.name}-lambda"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

data "aws_iam_policy_document" "artifact_read" {
  statement {
    sid       = "ReadPublishedPackages"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:${local.partition}:s3:::${var.artifact_bucket}/api/*"]
  }
}

resource "aws_iam_role_policy" "artifact_read" {
  name   = "${var.name}-artifacts"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.artifact_read.json
}
