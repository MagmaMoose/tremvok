output "api_url" {
  description = "Base URL to give the action's `api-url` input."
  value       = var.localstack ? trimsuffix(aws_lambda_function_url.local[0].function_url, "/") : aws_apigatewayv2_api.api[0].api_endpoint
}

output "healthz_url" {
  description = "Liveness endpoint. MUST return 200 after the first apply — verify with a real request, not by reading the plan."
  value       = "${var.localstack ? trimsuffix(aws_lambda_function_url.local[0].function_url, "/") : aws_apigatewayv2_api.api[0].api_endpoint}/healthz"
}

output "function_name" {
  description = "Lambda function name, for `aws lambda invoke` and for the action's lambda-zip target."
  value       = aws_lambda_function.api.function_name
}

output "table_name" {
  description = "DynamoDB table holding the deployment history."
  value       = aws_dynamodb_table.deployments.name
}

output "artifact_key" {
  description = "The S3 key this deployment is pinned to. Bumping `artifact_version` is the deployment."
  value       = local.artifact_key
}

output "role_arn" {
  description = "The function's execution role."
  value       = aws_iam_role.lambda.arn
}
