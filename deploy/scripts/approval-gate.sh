#!/usr/bin/env bash
# Who has independently approved this pull request?
#
# "Independently" means: not its author, and counting only each reviewer's most recent decisive
# review — so a later CHANGES_REQUESTED or a dismissal revokes an earlier approval, and a
# COMMENTED review counts for nothing. Getting that wrong in either direction is serious: too
# lenient and a dismissed approval still authorises an apply, too strict and nothing ever
# applies.
#
# Approving does not grant new power. Anyone who can approve can already merge, and merging is
# what applies today — this only moves the apply to *before* the merge, where a failure is
# still cheap to undo.
#
# Prints one login per line. Exit 1 means the review list could not be read, which must never
# be mistaken for "nobody approved": the caller has to fail closed on it.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
AUTH_TOKEN="${AUTH_TOKEN:-${GITHUB_TOKEN:-}}"
PR_NUMBER="${PR_NUMBER:-${1:-}}"

tremvok::require GITHUB_REPOSITORY
tremvok::require AUTH_TOKEN "a token with pull-requests: read"
[[ -n "$PR_NUMBER" ]] || tremvok::fail "approval-gate needs a pull-request number"

api() {
  curl --silent --show-error --fail --location --max-time 20 \
    --header "authorization: Bearer ${AUTH_TOKEN}" \
    --header 'accept: application/vnd.github+json' \
    --header 'x-github-api-version: 2022-11-28' \
    "$@"
}

author="$(api "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" | jq -r '.user.login // empty')" \
  || tremvok::fail "could not read pull request #${PR_NUMBER}"
[[ -n "$author" ]] || tremvok::fail "pull request #${PR_NUMBER} has no author; refusing to guess"

reviews="[]"
page=1
while (( page <= 10 )); do
  batch="$(api "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/reviews?per_page=100&page=${page}")" \
    || tremvok::fail "could not read the reviews of #${PR_NUMBER}"
  count="$(jq 'length' <<<"$batch")"
  reviews="$(jq -s 'add' <<<"${reviews}${batch}")"
  (( count == 100 )) || break
  page=$(( page + 1 ))
done

jq -r --arg author "$author" '
  [ .[]
    | select(.user.login != $author)
    | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED") ]
  | sort_by([.user.login, .submitted_at])
  | group_by(.user.login)
  | map(.[-1] | select(.state == "APPROVED") | .user.login)
  | unique | .[]
' <<<"$reviews"
