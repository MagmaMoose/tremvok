#!/usr/bin/env bash
# Work out what this event changed, then hand it to the Terragrunt target.
#
# Computed here rather than inside deploy-terragrunt.sh so that script stays testable
# without a git checkout or a GitHub API, and read from the API rather than `git diff` on a
# pull request because a shallow clone silently finds nothing — which discovers zero stacks
# and reports "this change touches no Terraform" about a change that touches plenty.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${here}/lib/common.sh"

GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
AUTH_TOKEN="${AUTH_TOKEN:-${GITHUB_TOKEN:-}}"
PR_NUMBER="${PR_NUMBER:-}"
EVENT_BEFORE="${EVENT_BEFORE:-}"
MAX_PAGES="${MAX_PAGES:-30}"

changed="${RUNNER_TEMP:-/tmp}/tremvok-changed-files.txt"
: >"$changed"

if [[ -n "$PR_NUMBER" ]]; then
  page=1
  while (( page <= MAX_PAGES )); do
    body="$(curl -fsSL --retry 2 \
      -H "authorization: Bearer ${AUTH_TOKEN}" \
      -H 'accept: application/vnd.github+json' \
      "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/files?per_page=100&page=${page}")"
    count="$(jq 'length' <<<"$body")"
    jq -r '.[].filename' <<<"$body" >>"$changed"
    # A short page is the last one. Stop at MAX_PAGES rather than paginate forever.
    (( count == 100 )) || break
    page=$(( page + 1 ))
  done
elif [[ "${GITHUB_EVENT_NAME:-}" == push && -n "$EVENT_BEFORE" ]]; then
  # Needs `fetch-depth: 0` on the checkout, which the action sets for this target. A shallow
  # clone cannot reach the "before" commit and would report zero changed files.
  git diff --name-only "$EVENT_BEFORE" "${GITHUB_SHA:-HEAD}" >"$changed" 2>/dev/null || true
fi

tremvok::log "$(wc -l <"$changed" | tr -d ' ') changed file(s)"
CHANGED_FILES="$changed" exec bash "${here}/deploy-terragrunt.sh"
