# A LocalStack root that stands the whole stack up exactly as a real leaf would.
#
# It exists because the production leaf cannot run locally: it would generate a remote backend
# and a provider pointed at a real account. This root supplies a local backend and the
# LocalStack-pointed provider below, and otherwise calls the *same module* — so what is
# exercised here is the real module code, including the IAM policy, the DynamoDB schema and
# the environment the function actually reads.
#
# WHAT A LOCAL RUN DOES NOT PROVE — both because the free LocalStack image cannot:
#
#   API Gateway        Pro-only, so `localstack = true` swaps in a Lambda Function URL. The
#                      substitution is honest — HTTP API payload format 2.0 is byte-for-byte
#                      what a Function URL delivers, so handler and downstream are identical —
#                      but the gateway's own configuration (the throttle, the `$default` stage,
#                      the integration) is never exercised. **Verify the throttle against the
#                      real thing after the first apply, not here.**
#   CloudWatch alarms  accepted and never evaluated, so none are created.

terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "api_zip_path" {
  description = <<-EOT
    The built Lambda package. `make -C terraform api-zip` produces it with this repository's own
    `scripts/build_api_zip.py` — deliberately the same script CI publishes with, so a local run
    and a released artifact cannot be built differently.
  EOT
  type        = string
}

variable "architecture" {
  description = <<-EOT
    Must match how the zip was built. LocalStack runs the function in a container of this
    architecture, so an arm64 zip on an x86_64 host (or the reverse) imports `pydantic_core`
    and fails — the Makefile derives it from `uname -m` for exactly this reason.
  EOT
  type        = string
  default     = "arm64"
}

variable "artifact_version" {
  description = "Version label for the locally-built package."
  type        = string
  default     = "0.0.0-local"
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = "tremvok-artifacts-local"
  force_destroy = true
}

# Stands in for the publish step, which is the only thing that writes here in production.
# Present ONLY in this root: the production leaf never uploads an artifact, because a Terraform
# run that can rewrite the code it deploys is a Terraform run that can deploy something nobody
# reviewed.
resource "aws_s3_object" "api" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "api/${var.artifact_version}.zip"
  source = var.api_zip_path
  etag   = filemd5(var.api_zip_path)
}

# A second bucket, standing in for a product's static site. Nothing in the API uses it; it is
# what `make smoke` points the action's `s3-cloudfront` target at, so the deploy path is
# exercised against a real S3 rather than a stub.
resource "aws_s3_bucket" "site" {
  bucket        = "tremvok-site-local"
  force_destroy = true
}

module "api" {
  source = "../modules/tremvok-api"

  name             = "tremvok-api"
  environment      = "local"
  region           = "eu-west-1"
  localstack       = true
  architecture     = var.architecture
  artifact_bucket  = aws_s3_bucket.artifacts.id
  artifact_version = var.artifact_version
  parameter_prefix = "/tremvok/local"
  oidc_audience    = "tremvok"
  allowed_owners   = ["MagmaMoose", "CalebSargeant"]

  # The function reads its package at create time, so the object has to exist first. Terraform
  # cannot infer this: the module takes a bucket NAME and a version string, neither of which
  # references the object resource.
  depends_on = [aws_s3_object.api]
}

output "api_url" { value = module.api.api_url }
output "healthz_url" { value = module.api.healthz_url }
output "function_name" { value = module.api.function_name }
output "table_name" { value = module.api.table_name }
output "artifact_bucket" { value = aws_s3_bucket.artifacts.id }
output "site_bucket" { value = aws_s3_bucket.site.id }
