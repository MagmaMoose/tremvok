#!/usr/bin/env bash
# Prove the thing that was uploaded is the thing now being served.
#
#   "A deploy that uploads but does not bind is the failure worth catching: the old version
#    keeps serving and everything looks green."   — dunmir/deploy-frontend.yml
#
# That is the entire justification for this file. A successful `aws s3 sync` means the objects
# are in the bucket; it says nothing about whether CloudFront serves them, whether the
# invalidation landed, or whether the distribution is even pointed at that bucket. A successful
# `update-function-code` says nothing about whether the alias moved.
#
# Two checks, both opt-in:
#   verify-url     the URL answers with the expected status, with retries for propagation
#   verify-header  a named response header is present (and optionally matches a pattern)
set -euo pipefail
# shellcheck source=deploy/scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

VERIFY_URL="${VERIFY_URL:-}"
VERIFY_HEADER="${VERIFY_HEADER:-}"
VERIFY_HEADER_MATCH="${VERIFY_HEADER_MATCH:-}"
EXPECT_STATUS="${EXPECT_STATUS:-200}"
ATTEMPTS="${ATTEMPTS:-6}"
DELAY="${DELAY:-10}"
TIMEOUT="${TIMEOUT:-15}"

if [[ -z "$VERIFY_URL" ]]; then
  tremvok::log "no verify-url set; skipping post-deploy verification"
  tremvok::set_output verified "false"
  tremvok::set_output verify-skipped "true"
  exit 0
fi

case "$VERIFY_URL" in
  https://*|http://*) ;; # DevSkim: ignore DS137138 - case pattern, not an http call
  *) tremvok::fail "verify-url must be an http(s) URL, got '${VERIFY_URL}'" ;;
esac

headers_file="$(mktemp)"
trap 'rm -f "$headers_file"' EXIT

# check_once is invoked by name via tremvok::retry on the line below
# shellcheck disable=SC2329
check_once() {
  local status
  # -D dumps the response headers so one request answers both questions. `--fail` is
  # deliberately NOT used: a 403 is a result to report, not a curl error to hide.
  status="$(curl --silent --show-error --location --max-time "$TIMEOUT" \
    --dump-header "$headers_file" --output /dev/null \
    --write-out '%{http_code}' "$VERIFY_URL" 2>/dev/null || printf '000')"

  if [[ "$status" != "$EXPECT_STATUS" ]]; then
    tremvok::log "  ${VERIFY_URL} -> ${status} (want ${EXPECT_STATUS})"
    return 1
  fi

  if [[ -n "$VERIFY_HEADER" ]]; then
    local line
    # Header names are case-insensitive on the wire, and HTTP/2 lower-cases them, so a
    # case-sensitive grep here would pass on HTTP/2 and fail on HTTP/1.1 for the same server.
    line="$(grep -i "^${VERIFY_HEADER}:" "$headers_file" | tail -1 || true)"
    if [[ -z "$line" ]]; then
      tremvok::log "  ${VERIFY_URL} -> ${status}, but the '${VERIFY_HEADER}' header is absent"
      return 1
    fi
    if [[ -n "$VERIFY_HEADER_MATCH" ]] && ! grep -qiE "$VERIFY_HEADER_MATCH" <<<"$line"; then
      tremvok::log "  '${VERIFY_HEADER}' is present but does not match /${VERIFY_HEADER_MATCH}/"
      return 1
    fi
  fi
  return 0
}

tremvok::log "verifying ${VERIFY_URL} (expect ${EXPECT_STATUS}${VERIFY_HEADER:+, header ${VERIFY_HEADER}})"
if tremvok::retry "$ATTEMPTS" "$DELAY" check_once; then
  tremvok::log "verified"
  tremvok::set_output verified "true"
  tremvok::set_output verify-skipped "false"
  exit 0
fi

tremvok::set_output verified "false"
tremvok::set_output verify-skipped "false"
# Single quotes inside ${VERIFY_HEADER:+...} are literal cosmetic chars, not shell quoting
# shellcheck disable=SC2016
tremvok::fail "post-deploy verification failed after ${ATTEMPTS} attempts: ${VERIFY_URL} never answered ${EXPECT_STATUS}${VERIFY_HEADER:+ with a '${VERIFY_HEADER}' header}. The upload may have succeeded while the old version is still being served."
