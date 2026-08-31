#!/usr/bin/env bash
# Publish a check run against a commit, so a pull request can *require* it.
#
# The point of a check run rather than a job status: a required check that reports
# `action_required` blocks the merge until the apply has actually run, which is what makes
# "apply before merge" enforceable rather than a convention.
#
# Corollary, and the trap: **a required check that never reports blocks the pull request
# forever.** So every pull request in scope gets one — including the ones that touch nothing,
# which report success with "nothing to do" rather than staying silent.
set -euo pipefail
# shellcheck source=deploy/scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
AUTH_TOKEN="${AUTH_TOKEN:-${GITHUB_TOKEN:-}}"
CHECK_NAME="${CHECK_NAME:-Tremvok apply}"
HEAD_SHA="${HEAD_SHA:-}"
CONCLUSION="${CONCLUSION:-success}"
TITLE="${TITLE:-}"
SUMMARY="${SUMMARY:-}"
DETAILS_URL="${DETAILS_URL:-}"

if [[ -z "$HEAD_SHA" ]]; then
  tremvok::log "no head sha in scope; not publishing a check run"
  exit 0
fi
if [[ -z "$AUTH_TOKEN" ]]; then
  tremvok::warn "no token available to publish the '${CHECK_NAME}' check run (needs checks: write)."
  exit 0
fi

case "$CONCLUSION" in
  success|failure|neutral|cancelled|timed_out|action_required|skipped) ;;
  *) tremvok::fail "invalid check conclusion '${CONCLUSION}'" ;;
esac

payload="$(jq -n \
  --arg name "$CHECK_NAME" --arg head_sha "$HEAD_SHA" --arg conclusion "$CONCLUSION" \
  --arg title "${TITLE:-$CHECK_NAME}" --arg summary "${SUMMARY:-}" --arg details_url "$DETAILS_URL" '
  {
    name: $name, head_sha: $head_sha, status: "completed", conclusion: $conclusion,
    output: {title: $title, summary: $summary}
  } + (if $details_url == "" then {} else {details_url: $details_url} end)')"

if curl --silent --show-error --fail --max-time 20 --request POST \
    --header "authorization: Bearer ${AUTH_TOKEN}" \
    --header 'accept: application/vnd.github+json' \
    --header 'x-github-api-version: 2022-11-28' \
    --data "$payload" \
    "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/check-runs" >/dev/null; then
  tremvok::log "published '${CHECK_NAME}' = ${CONCLUSION} on ${HEAD_SHA:0:12}"
else
  # A warning, not a failure: the check run is how the *result* is reported, and failing the
  # job because the report did not post makes the outcome less visible, not more.
  tremvok::warn "could not publish the '${CHECK_NAME}' check run."
fi
