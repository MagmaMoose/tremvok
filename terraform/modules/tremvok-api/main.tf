data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  artifact_key = "api/${var.artifact_version}.zip"

  tags = merge(
    {
      Application = "tremvok"
      Component   = "api"
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "MagmaMoose/tremvok"
    },
    var.tags,
  )
}
