#!/usr/bin/env bash
# Exchange this run's GitHub OIDC token for short-lived AWS credentials.
#
# No access key is stored in any repository. GitHub mints a token for this run, STS trades it
# for credentials that expire in an hour, and the role's trust policy decides which repository
# and which ref may do that. This is the single strongest argument for moving deployment into
# GitHub Actions: the credential Atlantis needs *at rest* — one able to create IAM roles and
# policies, and therefore able to grant itself anything — stops existing.
#
# Deliberately not `aws-actions/configure-aws-credentials`. It is a fine action, and a
# repository that prefers it can run it in an earlier step and leave `role-to-assume` empty:
# `preflight.sh` accepts ambient credentials. What it costs is a third-party dependency inside
# the step that holds production credentials, for an exchange that is one STS call.
set -euo pipefail
# shellcheck source=deploy/scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ROLE_TO_ASSUME="${ROLE_TO_ASSUME:-}"
AWS_REGION="${AWS_REGION:-}"
ROLE_SESSION_NAME="${ROLE_SESSION_NAME:-}"
ROLE_DURATION_SECONDS="${ROLE_DURATION_SECONDS:-3600}"
STS_AUDIENCE="${STS_AUDIENCE:-sts.amazonaws.com}"

if [[ -z "$ROLE_TO_ASSUME" ]]; then
  tremvok::log "no role-to-assume; using whatever credentials the job already has"
  exit 0
fi

if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" || -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
  tremvok::fail "role-to-assume is set but this job cannot mint an OIDC token. Add 'permissions: id-token: write' to the workflow."
fi

if [[ -z "$ROLE_SESSION_NAME" ]]; then
  # STS caps the session name at 64 characters and rejects '/', which every repository name
  # contains. The run id keeps sessions distinguishable in CloudTrail.
  ROLE_SESSION_NAME="tremvok-$(tremvok::slug "${GITHUB_REPOSITORY:-local}")-${GITHUB_RUN_ID:-0}"
  ROLE_SESSION_NAME="${ROLE_SESSION_NAME:0:64}"
fi

token="$(curl --silent --show-error --fail --max-time 15 \
  --header "authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${STS_AUDIENCE}" | jq -r '.value // empty')" \
  || tremvok::fail "could not mint an OIDC token for audience '${STS_AUDIENCE}'"
[[ -n "$token" ]] || tremvok::fail "GitHub returned an empty OIDC token"

credentials="$(aws sts assume-role-with-web-identity \
  --role-arn "$ROLE_TO_ASSUME" \
  --role-session-name "$ROLE_SESSION_NAME" \
  --web-identity-token "$token" \
  --duration-seconds "$ROLE_DURATION_SECONDS" \
  --query 'Credentials' --output json)" \
  || tremvok::fail "STS refused to assume ${ROLE_TO_ASSUME}. Check the role's trust policy allows this repository and ref."

access_key="$(jq -r '.AccessKeyId' <<<"$credentials")"
secret_key="$(jq -r '.SecretAccessKey' <<<"$credentials")"
session_token="$(jq -r '.SessionToken' <<<"$credentials")"
[[ -n "$access_key" && "$access_key" != "null" ]] || tremvok::fail "STS returned no credentials"

# Mask before exporting. A later step that echoes its environment — or a tool that dumps its
# config on error — would otherwise print the secret into a log anyone with read access keeps.
printf '::add-mask::%s\n' "$secret_key"
printf '::add-mask::%s\n' "$session_token"

{
  printf 'AWS_ACCESS_KEY_ID=%s\n' "$access_key"
  printf 'AWS_SECRET_ACCESS_KEY=%s\n' "$secret_key"
  printf 'AWS_SESSION_TOKEN=%s\n' "$session_token"
  [[ -n "$AWS_REGION" ]] && printf 'AWS_REGION=%s\nAWS_DEFAULT_REGION=%s\n' "$AWS_REGION" "$AWS_REGION"
} >>"${GITHUB_ENV:-/dev/null}"

# GITHUB_ENV only takes effect in *later* steps, so the identity check has to use the
# credentials in this shell. Worth the extra call: "assumed the role" and "the role can do
# anything" are different claims, and an expired or mis-scoped session otherwise surfaces
# several steps later as a confusing AccessDenied on the deploy itself.
export AWS_ACCESS_KEY_ID="$access_key"
export AWS_SECRET_ACCESS_KEY="$secret_key"
export AWS_SESSION_TOKEN="$session_token"
[[ -n "$AWS_REGION" ]] && export AWS_DEFAULT_REGION="$AWS_REGION"

identity="$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || echo unknown)"
tremvok::log "assumed ${ROLE_TO_ASSUME} as ${ROLE_SESSION_NAME} (${identity})"
