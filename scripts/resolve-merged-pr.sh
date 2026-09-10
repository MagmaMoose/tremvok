#!/usr/bin/env bash
# Which pull request was this commit merged from?
#
# A push to the default branch carries no pull request in its event payload, so the approval
# that authorises the apply has to be found from the commit itself.
# `GET /repos/{repo}/commits/{sha}/pulls` answers it, and associates squash, merge-commit and
# rebase merges alike.
#
# The contract, and the whole reason this is a script of its own rather than three lines
# inline: it prints the pull-request number on stdout, or nothing, and returns THREE exit
# codes, because collapsing two of them is the bug this guards against.
#
#   0   a merged pull request; its number is on stdout
#   2   the API answered and this commit came from no merged pull request (a direct push)
#   1   the API could not be read, and that must never be read as "no merged pull request"
#
# An outage that reads as 2 turns into a silent skip, or worse an apply with no approval
# behind it. `tremvok::fail` is exit 1, so the unreadable path is exit 1 by construction.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
AUTH_TOKEN="${AUTH_TOKEN:-${GITHUB_TOKEN:-}}"
SHA="${SHA:-${GITHUB_SHA:-}}"
[[ -n "$SHA" ]] || SHA="${1:-}"
# The branch the push landed on. Part of the tie-break below; empty just means the tie-break
# falls through to the merge time.
BASE_REF="${BASE_REF:-${GITHUB_REF_NAME:-}}"

tremvok::require GITHUB_REPOSITORY
tremvok::require AUTH_TOKEN "a token with pull-requests: read"
# Rather than requesting /commits//pulls, which 404s and reads as "no merged pull request"
# on an endpoint that was never asked the question.
[[ -n "$SHA" ]] || tremvok::fail "resolve-merged-pr needs a commit sha"

# `--fail` is what turns a 4xx or 5xx into a non-zero exit rather than an empty list, which
# is the difference between exit 1 and exit 2 here. An unknown sha is a 404, so a sha the API
# will not confirm fails closed.
#
# `--retry 2`, matching terragrunt-pr-head.sh and the other GitHub calls in this repository.
# Under `terragrunt-apply-on-merge` a failure here fails the run, so without a retry one
# transient 5xx turns a successful merge red. curl does not retry a 4xx, so a genuinely
# missing sha still fails once rather than three times.
body="$(curl --silent --show-error --fail --location --retry 2 --max-time 20 \
  --header "authorization: Bearer ${AUTH_TOKEN}" \
  --header 'accept: application/vnd.github+json' \
  --header 'x-github-api-version: 2022-11-28' \
  "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/commits/${SHA}/pulls?per_page=100")" \
  || tremvok::fail "could not read the pull requests for ${SHA}"

# One page only. A commit belongs to a handful of pull requests at most, and paginating a list
# that is never long only widens the window in which the answer is unreadable.
#
# Which pull request's approvals authorise the apply must not depend on the order the API
# happened to return, so the tie-break is stated here and implemented below, in this order:
#
#   1. a merged pull request whose `base.ref` is the branch this push landed on. That is the
#      merge that put the commit where it now is, and its review is the one that authorised
#      it. GITHUB_REF_NAME is the branch; empty skips straight to rule 2.
#   2. among the rest, or among several rule-1 matches, the OLDEST `merged_at` wins: where a
#      branch was merged into another branch first, the earliest association is the review
#      the commit actually passed through.
#
# `.[0]` of an empty array is null and `null.number` is null, so `// empty` prints nothing and
# the exit-2 path below is reached. `sort_by(.merged_at // "")` keeps a payload with a missing
# merged_at from failing the whole program.
number="$(jq -r --arg base "$BASE_REF" '
    [ .[] | select(.merged_at != null) ] as $merged
    | [ $merged[] | select($base != "" and (.base.ref? == $base)) ] as $on_base
    | (if ($on_base | length) > 0 then $on_base else $merged end)
    | sort_by(.merged_at // "")
    | (.[0].number // empty)
  ' <<<"$body")" \
  || tremvok::fail "the pull-request list for ${SHA} was not readable JSON"

if [[ -z "$number" ]]; then
  # To stderr, not stdout. The caller captures stdout, so stdout is the number or it is
  # nothing: a log line there becomes the "pull request number" of any caller that reads the
  # output before the exit code.
  tremvok::log "${SHA} came from no merged pull request" >&2
  exit 2
fi
printf '%s\n' "$number"
