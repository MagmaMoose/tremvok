#!/usr/bin/env bash
# The head commit of one pull request, named by number.
#
# `terragrunt-pull-request` exists for a manual run that has to plan or apply a named pull
# request, and a dispatch event carries no `pull_request` object at all. Without this the head
# sha falls through to `github.sha`, the tip of the branch the run started from, and the check
# run lands on a commit no merge button is waiting on.
#
# **Prints the sha on stdout and nothing else.** Every human-readable line goes to stderr
# through `tremvok::error`, because the caller captures stdout: a stray log line here becomes
# the "sha" a check run is published against.
#
# A failure here ends the run. The number is an instruction, not a report: if the pull request
# cannot be read then its reviews cannot be read either, and the alternative to failing is a
# run that plans, cannot apply, and publishes no check at all.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
AUTH_TOKEN="${AUTH_TOKEN:-${GITHUB_TOKEN:-}}"
PR_NUMBER="${PR_NUMBER:-${1:-}}"

tremvok::require GITHUB_REPOSITORY
tremvok::require AUTH_TOKEN "a token with pull-requests: read"
# Re-asserted here rather than trusted from the caller: this script builds an API URL path
# segment out of the value, and it is run directly by the tests.
tremvok::require_pr_number terragrunt-pull-request "$PR_NUMBER"

# The same endpoint and headers approval-gate.sh already uses, so it works unchanged on
# github.com and GHES and needs nothing installed. `--retry 2` because a manual run should
# survive one transient 5xx; curl does not retry a 4xx, so a wrong number fails once rather
# than three times.
body="$(curl --silent --show-error --fail --location --retry 2 --max-time 20 \
  --header "authorization: Bearer ${AUTH_TOKEN}" \
  --header 'accept: application/vnd.github+json' \
  --header 'x-github-api-version: 2022-11-28' \
  "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}")" \
  || tremvok::fail "could not read pull request #${PR_NUMBER} from ${GITHUB_REPOSITORY}. terragrunt-pull-request names one this run cannot see: a wrong number, or a token without pull-requests: read."

# preflight.sh refuses fork code before it reaches a deploy credential, but it reads
# github.event.pull_request.head.repo.fork, which a dispatch does not have. Without this the
# manual path is the one hole through which an operator can aim a runner's cloud role at fork
# code. The same response already carries the flag, so it costs no extra call.
fork="$(jq -r '.head.repo.fork // false' <<<"$body")" \
  || tremvok::fail "pull request #${PR_NUMBER} did not come back as readable JSON"
[[ "$fork" != "true" ]] \
  || tremvok::fail "pull request #${PR_NUMBER} comes from a fork. The automatic path refuses fork code before it reaches a deploy credential, and the manual path does the same."

sha="$(jq -r '.head.sha // empty' <<<"$body")"
[[ -n "$sha" ]] \
  || tremvok::fail "pull request #${PR_NUMBER} reports no head commit, so there is nothing to publish the check run against."

printf '%s\n' "$sha"
