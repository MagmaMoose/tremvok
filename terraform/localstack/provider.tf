# Everything points at LocalStack. The credentials are the literal strings LocalStack expects;
# they authenticate nothing and reach nothing.
provider "aws" {
  region     = "eu-west-1"
  access_key = "test"
  secret_key = "test"

  # Without these the provider spends the first minute of every apply trying to reach the real
  # IAM and STS endpoints before failing in a way that reads like a network problem.
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  skip_region_validation      = true

  # Path-style addressing: virtual-host style would resolve `bucket.localhost` through real DNS.
  s3_use_path_style = true

  endpoints {
    apigateway   = "http://localhost:4566"
    apigatewayv2 = "http://localhost:4566"
    cloudwatch   = "http://localhost:4566"
    dynamodb     = "http://localhost:4566"
    iam          = "http://localhost:4566"
    kms          = "http://localhost:4566"
    lambda       = "http://localhost:4566"
    logs         = "http://localhost:4566"
    s3           = "http://localhost:4566"
    s3control    = "http://localhost:4566"
    sns          = "http://localhost:4566"
    ssm          = "http://localhost:4566"
    sts          = "http://localhost:4566"
  }
}
