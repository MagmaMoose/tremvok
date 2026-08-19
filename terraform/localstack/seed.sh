#!/usr/bin/env bash
# Put the webhook URLs the API reads into LocalStack's SSM Parameter Store.
#
# Terraform deliberately does NOT create these. A secret in a Terraform resource is a secret in
# Terraform state, and this stack's state would otherwise be the one thing in it worth stealing.
# In production they are written once with `aws ssm put-parameter` (see terraform/README.md);
# here they point at a local sink so the notification path is exercised rather than assumed.
set -euo pipefail

: "${AWS_ENDPOINT_URL:=http://localhost:4566}"  # DevSkim: ignore DS162092
: "${AWS_DEFAULT_REGION:=eu-west-1}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"

PREFIX="${1:-/tremvok/local}"

put() {
  aws --endpoint-url="$AWS_ENDPOINT_URL" ssm put-parameter \
    --name "${PREFIX}/$1" --value "$2" --type SecureString --overwrite >/dev/null
  echo "  ${PREFIX}/$1"
}

echo "seeding parameters:"
# Deliberately unreachable. The point is to prove the fan-out is attempted and that its failure
# is isolated — a Slack outage must not fail a deploy — so a URL that cannot resolve is a more
# useful test fixture than one that works.
put slack-webhook "https://hooks.slack.invalid/services/local/test"
