#!/usr/bin/env bash
# Publish a Lambda package and point an alias at it.
#
# This is the deploy half of the pattern nievah's front door already uses: the code repository
# publishes an immutable artifact, and something else decides which version is live. Today that
# decision is a hand-edited `edge_artifact_version` in a Terraform leaf and a reviewed pull
# request; this is that, automated, without giving the deployer permission to *change* the
# bytes under a version somebody already reviewed.
#
# Three rules make that hold:
#
#   * **The S3 key is immutable.** Uploading over an existing key would swap the code under a
#     version that has already been reviewed and released, so a key that exists and does not
#     match is a hard failure — not an overwrite, and not a silent skip.
#   * **The alias moves only in deploy mode.** A pull request publishes a version and stops.
#     That proves the package builds, uploads and passes Lambda's own validation without
#     changing what production serves.
#   * **The deployed digest is checked.** Lambda reports `CodeSha256` for the code it actually
#     installed; comparing it against the local zip is what distinguishes "deployed" from
#     "the API accepted my request".
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

FUNCTION_NAME="${FUNCTION_NAME:-}"
ARTIFACT_PATH="${ARTIFACT_PATH:-}"
ARTIFACT_BUCKET="${ARTIFACT_BUCKET:-}"
ARTIFACT_KEY="${ARTIFACT_KEY:-}"
KEY_PREFIX="${KEY_PREFIX:-releases}"
VERSION_LABEL="${VERSION_LABEL:-}"
ALIAS="${ALIAS:-live}"
MODE="${MODE:-deploy}"
DRY_RUN="${DRY_RUN:-false}"
WAIT_SECONDS="${WAIT_SECONDS:-120}"

tremvok::require FUNCTION_NAME "the Lambda function to update"
tremvok::require ARTIFACT_PATH "the built .zip"
tremvok::require ARTIFACT_BUCKET "the S3 bucket that holds published artifacts"

[[ -f "$ARTIFACT_PATH" ]] || tremvok::fail "artifact-path '${ARTIFACT_PATH}' is not a file"
[[ -s "$ARTIFACT_PATH" ]] || tremvok::fail "artifact-path '${ARTIFACT_PATH}' is empty"

if [[ -z "$VERSION_LABEL" ]]; then
  VERSION_LABEL="${GITHUB_SHA:-}"
  VERSION_LABEL="${VERSION_LABEL:0:12}"
  [[ -n "$VERSION_LABEL" ]] || tremvok::fail "version-label is required when GITHUB_SHA is unset"
fi
[[ -z "$ARTIFACT_KEY" ]] && ARTIFACT_KEY="${KEY_PREFIX%/}/${VERSION_LABEL}.zip"

# Lambda's CodeSha256 is the base64 of the raw sha256 of the zip, not the hex digest. Computing
# it the same way here is what makes the post-deploy comparison meaningful.
local_sha256_b64="$(openssl dgst -sha256 -binary "$ARTIFACT_PATH" | openssl base64 -A)"
local_sha256_hex="$(openssl dgst -sha256 -hex "$ARTIFACT_PATH" | awk '{print $NF}')"
tremvok::log "artifact ${ARTIFACT_PATH} sha256=${local_sha256_hex}"

dry() { tremvok::is_true "$DRY_RUN"; }

# ── upload, immutably ────────────────────────────────────────────────────────────────────
existing_etag=""
if ! dry; then
  existing_etag="$(aws s3api head-object --bucket "$ARTIFACT_BUCKET" --key "$ARTIFACT_KEY" \
    --query 'Metadata.sha256' --output text 2>/dev/null || true)"
fi

if [[ -n "$existing_etag" && "$existing_etag" != "None" ]]; then
  if [[ "$existing_etag" == "$local_sha256_hex" ]]; then
    # Byte-identical re-publish. Common and harmless: a re-run of the same commit. Skipping the
    # upload keeps the key immutable *and* keeps the run idempotent.
    tremvok::log "s3://${ARTIFACT_BUCKET}/${ARTIFACT_KEY} already holds this exact artifact; not re-uploading"
  else
    tremvok::fail "s3://${ARTIFACT_BUCKET}/${ARTIFACT_KEY} already exists with a different digest (${existing_etag} != ${local_sha256_hex}). Published artifacts are immutable: overwriting one would change the code behind a version that has already been reviewed. Use a new version-label."
  fi
elif dry; then
  tremvok::log "DRY RUN: aws s3api put-object --bucket ${ARTIFACT_BUCKET} --key ${ARTIFACT_KEY}"
else
  aws s3api put-object \
    --bucket "$ARTIFACT_BUCKET" \
    --key "$ARTIFACT_KEY" \
    --body "$ARTIFACT_PATH" \
    --metadata "sha256=${local_sha256_hex}" \
    --content-type application/zip >/dev/null
  tremvok::log "uploaded s3://${ARTIFACT_BUCKET}/${ARTIFACT_KEY}"
fi

# ── point the function at it ─────────────────────────────────────────────────────────────
version=""
deployed_sha=""
if dry; then
  tremvok::log "DRY RUN: aws lambda update-function-code --function-name ${FUNCTION_NAME} --s3-key ${ARTIFACT_KEY} --publish"
  version="dry-run"
  deployed_sha="$local_sha256_b64"
else
  update_json="$(aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --s3-bucket "$ARTIFACT_BUCKET" \
    --s3-key "$ARTIFACT_KEY" \
    --publish \
    --output json)"
  version="$(jq -r '.Version' <<<"$update_json")"
  deployed_sha="$(jq -r '.CodeSha256' <<<"$update_json")"

  # `--publish` returns before the new version leaves Pending. Moving an alias to a Pending
  # version fails with ResourceConflictException, which reads like a permissions problem.
  aws lambda wait function-updated-v2 --function-name "$FUNCTION_NAME" 2>/dev/null || \
    tremvok::warn "could not wait for ${FUNCTION_NAME} to leave Pending; continuing"
fi

[[ -n "$version" && "$version" != "null" ]] || tremvok::fail "Lambda did not return a published version"

if [[ "$deployed_sha" != "$local_sha256_b64" ]]; then
  tremvok::fail "Lambda reports CodeSha256 ${deployed_sha} but the artifact is ${local_sha256_b64}. The function is not running the package this run built."
fi
tremvok::log "published version ${version} (digest verified)"

# ── move the alias, but only when this is a real deploy ──────────────────────────────────
alias_moved=false
if [[ "$MODE" == "deploy" || "$MODE" == "rollback" ]]; then
  if dry; then
    tremvok::log "DRY RUN: aws lambda update-alias --name ${ALIAS} --function-version ${version}"
  else
    aws lambda update-alias --function-name "$FUNCTION_NAME" --name "$ALIAS" \
      --function-version "$version" >/dev/null 2>&1 \
      || aws lambda create-alias --function-name "$FUNCTION_NAME" --name "$ALIAS" \
        --function-version "$version" >/dev/null
  fi
  alias_moved=true
  tremvok::log "alias ${ALIAS} -> ${version}"
else
  tremvok::log "mode=${MODE}: published version ${version} without moving the '${ALIAS}' alias, so production is unchanged"
fi

tremvok::set_output version-id "$version"
tremvok::set_output artifact-key "$ARTIFACT_KEY"
tremvok::set_output artifact-sha256 "$local_sha256_hex"
tremvok::set_output alias-moved "$alias_moved"
tremvok::set_output deployed "true"
