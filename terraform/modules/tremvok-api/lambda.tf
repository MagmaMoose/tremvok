# The log group is created here, with a retention policy, rather than left to the function to
# create on first use — a Lambda-created group defaults to `never expire`, which is the one way
# this stack accumulates storage nobody is watching.
#trivy:ignore:AWS-0017
resource "aws_cloudwatch_log_group" "lambda" {
  #checkov:skip=CKV_AWS_158:KMS CMK for CloudWatch costs $1/month per key on a personally-funded account; AWS-managed encryption is sufficient
  #checkov:skip=CKV_AWS_338:Retention period is set via var.log_retention_days; compliance duration is the caller's responsibility
  name              = "/aws/lambda/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

#trivy:ignore:AWS-0066
resource "aws_lambda_function" "api" {
  #checkov:skip=CKV_AWS_116:DLQ not applicable — function is behind API Gateway and failure-isolated; a failed delivery record is a deploy retry, not a dead letter
  #checkov:skip=CKV_AWS_117:Lambda does not need VPC placement — its job is receiving public HTTPS webhooks; VPC + NAT gateway adds real cost with no benefit here
  #checkov:skip=CKV_AWS_173:Environment variables are configuration only (table name, prefix, audience); every secret is read from SSM at runtime per the hard constraint
  #checkov:skip=CKV_AWS_272:Code signing not in use for this project; signing infrastructure would cost more than the service it protects
  function_name = var.name
  role          = aws_iam_role.lambda.arn

  s3_bucket = var.artifact_bucket
  s3_key    = local.artifact_key

  # `tremvok.aws.handler.handler` is Mangum wrapping the FastAPI app. Package layout is fixed
  # by scripts/build_api_zip.py, which is the one definition of what ships.
  handler       = "tremvok.aws.handler.handler"
  runtime       = "python3.12"
  architectures = [var.architecture]

  memory_size = var.memory_size
  timeout     = var.timeout

  # A hard ceiling on concurrent executions, redundant with the API Gateway throttle on
  # purpose: the throttle protects the front door, this protects the function even if
  # something reaches it another way.
  reserved_concurrent_executions = var.reserved_concurrency

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      # Configuration only. Every secret is read from SSM at runtime — a Lambda environment
      # variable is plaintext to anyone holding lambda:GetFunctionConfiguration, which is a far
      # wider audience than it looks.
      TREMVOK_TABLE            = aws_dynamodb_table.deployments.name
      TREMVOK_PARAMETER_PREFIX = var.parameter_prefix
      TREMVOK_OIDC_AUDIENCE    = var.oidc_audience
      TREMVOK_ALLOWED_OWNERS   = join(",", var.allowed_owners)
      TREMVOK_RETENTION_DAYS   = tostring(var.retention_days)
    }
  }

  # Without this the first invocation can race the log group into existence and create it
  # itself — without the retention policy above.
  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy.lambda]

  tags = local.tags
}

# ── The front door ───────────────────────────────────────────────────────────────────────
#
# Production is an HTTP API with a throttled `$default` stage. Locally it is a Function URL,
# because HTTP API is LocalStack Pro-only — see the `localstack` variable for what that
# substitution does and does not prove.

resource "aws_apigatewayv2_api" "api" {
  count = var.localstack ? 0 : 1

  name          = var.name
  protocol_type = "HTTP"

  tags = local.tags
}

resource "aws_apigatewayv2_integration" "lambda" {
  count = var.localstack ? 0 : 1

  api_id           = aws_apigatewayv2_api.api[0].id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.api.invoke_arn
  # 2.0 is what Mangum expects and what a Function URL delivers, which is what makes the
  # local substitution a true stand-in rather than a different code path.
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "proxy" {
  count = var.localstack ? 0 : 1

  api_id    = aws_apigatewayv2_api.api[0].id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda[0].id}"
}

resource "aws_apigatewayv2_stage" "default" {
  count = var.localstack ? 0 : 1

  api_id      = aws_apigatewayv2_api.api[0].id
  name        = "$default"
  auto_deploy = true

  # The cost ceiling. AWS has no spend cap and Budgets only report, so this is the control that
  # actually holds: over-limit requests get a 429 at the gateway and never become an
  # invocation. Sized as though nothing else were protecting the stack.
  default_route_settings {
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit
  }

  tags = local.tags
}

resource "aws_lambda_permission" "api_gateway" {
  count = var.localstack ? 0 : 1

  statement_id  = "AllowInvokeFromHttpApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api[0].execution_arn}/*/*"
}

resource "aws_lambda_function_url" "local" {
  #checkov:skip=CKV_AWS_258:AuthType NONE only exists when localstack=true; in production (count=0) this resource is never created and the front door is API Gateway
  count = var.localstack ? 1 : 0

  function_name = aws_lambda_function.api.function_name
  # NONE only ever exists in the LocalStack shape. In production the front door is the gateway
  # and the function has no URL of its own at all.
  authorization_type = "NONE"
}
