variable "name" {
  description = "Name prefix for every resource. One deployment per name."
  type        = string
  default     = "tremvok-api"
}

variable "environment" {
  description = "Logical environment (prod, local). Used in tags and the SSM parameter path."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
}

variable "artifact_bucket" {
  description = "S3 bucket holding published Lambda packages."
  type        = string
}

variable "artifact_version" {
  description = <<-EOT
    Which published package this deployment runs, as `api/<version>.zip` in `artifact_bucket`.

    **Changing this is the deployment.** Terraform deliberately does not upload the artifact:
    a Terraform run that could rewrite the code it deploys is a Terraform run that can deploy
    something nobody reviewed. The package is published by CI; this points at one.
  EOT
  type        = string
}

variable "architecture" {
  description = <<-EOT
    `arm64` (default) or `x86_64`. Graviton is ~20% cheaper per GB-second and is what
    `scripts/build_api_zip.py` builds for by default — the two must agree, because
    `pydantic-core` is a compiled wheel and a mismatch fails at the first request with
    `No module named 'pydantic_core._pydantic_core'`, not at deploy time.
  EOT
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "architecture must be arm64 or x86_64."
  }
}

variable "allowed_owners" {
  description = <<-EOT
    GitHub owners whose repositories may record deployments, e.g. ["MagmaMoose"].

    **Empty denies everything, on purpose.** GitHub issues an OIDC token to every repository on
    github.com, so a valid signature proves only that the caller is *a* workflow. This list is
    what makes it one of ours.
  EOT
  type        = list(string)
  default     = []
}

variable "oidc_audience" {
  description = "Audience the API requires in the OIDC token. Must match the action's `api-audience`."
  type        = string
  default     = "tremvok"
}

variable "retention_days" {
  description = "How long a deployment record lives before DynamoDB's TTL removes it."
  type        = number
  default     = 90
}

variable "log_retention_days" {
  description = <<-EOT
    CloudWatch Logs retention. The free allowance is 5 GB of ingestion and 5 GB of storage;
    `never expire` is the default AWS gives you and the one way this stack could accumulate a
    bill without anybody doing anything.
  EOT
  type        = number
  default     = 14
}

variable "throttle_rate_limit" {
  description = <<-EOT
    Requests per second the API Gateway stage accepts. This is the real cost ceiling: AWS has
    no spend cap, Budgets report rather than stop, and an over-limit request is rejected at the
    gateway for the price of a request rather than a request *and* a Lambda invocation.

    Steady state is a handful of deployments a day — call it 0.001 rps — so 2 rps is ~2000x
    headroom and still bounds the worst case to single-digit dollars a month.
  EOT
  type        = number
  default     = 2
}

variable "throttle_burst_limit" {
  description = "Burst allowance on top of `throttle_rate_limit`."
  type        = number
  default     = 10
}

variable "reserved_concurrency" {
  description = <<-EOT
    Maximum concurrent executions. A hard bound on how much Lambda this stack can ever consume
    at once, independent of the gateway throttle — the two are deliberately redundant, because
    the gateway can be bypassed if the execute-api endpoint is found and this cannot.
  EOT
  type        = number
  default     = 5
}

variable "memory_size" {
  description = <<-EOT
    Lambda memory in MB. 512 rather than the 128 default: FastAPI's import graph dominates the
    cold start, CPU scales with memory, and the free tier is measured in **GB-seconds** — so a
    function that finishes four times faster on four times the memory costs the same allowance
    and answers in a third of the time.
  EOT
  type        = number
  default     = 512
}

variable "timeout" {
  description = "Lambda timeout in seconds. Long enough for two webhook POSTs and a DynamoDB write."
  type        = number
  default     = 20
}

variable "parameter_prefix" {
  description = <<-EOT
    SSM Parameter Store prefix holding the webhook URLs, e.g. `/tremvok/prod`.

    Terraform deliberately does not create these parameters. A secret in a Terraform resource
    is a secret in Terraform state; they are written once by hand with `aws ssm put-parameter`.
  EOT
  type        = string
}

variable "alarm_actions" {
  description = "SNS topic ARNs notified when the function starts erroring. Empty means the alarm still exists and simply notifies nobody."
  type        = list(string)
  default     = []
}

variable "localstack" {
  description = <<-EOT
    Build the LocalStack-compatible shape instead of the production one.

    What changes, and what that costs in coverage:
      * **API Gateway becomes a Lambda Function URL.** HTTP API is Pro-only. The substitution
        is honest rather than lossy — payload format 2.0 is byte-for-byte the event a Function
        URL delivers, so the handler and everything downstream is the identical code path — but
        the gateway's OWN configuration (the throttle, the `$default` stage, the integration)
        is never exercised locally.
      * **CloudWatch alarms are skipped.** Accepted by the community image and never evaluated,
        so creating them would prove nothing and hide that.
  EOT
  type        = bool
  default     = false
}

variable "tags" {
  description = "Extra tags merged into every resource."
  type        = map(string)
  default     = {}
}
