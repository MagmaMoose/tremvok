# Deployment history. One partition per repository, sorted by time, with a TTL so it cannot
# grow without bound. See `src/tremvok/store.py` for the item shapes.
#trivy:ignore:AWS-0024
#trivy:ignore:AWS-0025
# nosemgrep: terraform.aws.security.aws-dynamodb-table-unencrypted.aws-dynamodb-table-unencrypted
resource "aws_dynamodb_table" "deployments" {
  #checkov:skip=CKV_AWS_28:PITR deliberately off — every row is a rolling 90-day deployment record re-derivable from workflow runs; backup bills per GB for data that is already a cache
  #checkov:skip=CKV_AWS_119:Customer-managed KMS key costs $1/month; most sensitive field is a git SHA; AWS-managed encryption is sufficient
  #checkov:skip=CKV2_AWS_16:Auto Scaling conflicts with PROVISIONED billing, which is the cost cap: on-demand cannot be capped so this table uses provisioned throttling instead
  name = var.name

  # PROVISIONED, not PAY_PER_REQUEST, and that is a cost control rather than a performance
  # choice. On-demand capacity cannot be capped: a runaway caller turns a free table into a
  # bill with no ceiling. Provisioned throttles instead, and a throttled deployment record is
  # a retry — the action treats the whole call as failure-isolated anyway.
  #
  # The always-free allowance is 25 read and 25 write units; 2 and 2 is inside it with room,
  # and this table is written a few times a day.
  billing_mode   = "PROVISIONED"
  read_capacity  = 2
  write_capacity = 2

  hash_key  = "pk"
  range_key = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  # Point-in-time recovery is deliberately off. It bills per GB of table size, and the contents
  # are a rolling 90 days of deployment records that are re-derivable from the workflow runs
  # that produced them. Backing up a cache is paying to keep something twice.
  point_in_time_recovery {
    enabled = false
  }

  # Encryption at rest with the AWS-owned key, which is free. A customer-managed KMS key would
  # add $1/month for a table whose most sensitive field is a git commit SHA.
  server_side_encryption {
    enabled = false
  }

  tags = local.tags
}
