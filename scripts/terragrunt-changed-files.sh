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
HEAD_SHA="${HEAD_SHA:-}"
TG_PULL_REQUEST="${TG_PULL_REQUEST:-}"
EVENT_BEFORE="${EVENT_BEFORE:-}"
MAX_PAGES="${MAX_PAGES:-30}"

# ── the pull request this run acts on ─────────────────────────────────────────────────────
# `terragrunt-pull-request` is the one resolution point for the override: everything below,
# and everything deploy-terragrunt.sh does with it (the approval gate, the plan comment, the
# check run), reads PR_NUMBER out of the environment. A dispatch carries no pull_request
# object, so the head sha has to be fetched rather than derived, and a fetch that fails ends
# the run here, before terragrunt-discover.sh, before any init, plan or state lock.
if [[ -n "$TG_PULL_REQUEST" ]]; then
  tremvok::require_pr_number terragrunt-pull-request "$TG_PULL_REQUEST"
  PR_NUMBER="$TG_PULL_REQUEST"
  # `if !` rather than a bare assignment: a command substitution that fails takes the
  # assignment down with it under `set -e` and never reaches a message of its own.
  if ! HEAD_SHA="$(PR_NUMBER="$PR_NUMBER" "${here}/terragrunt-pr-head.sh")"; then
    tremvok::fail "terragrunt-pull-request: #${PR_NUMBER} has no head commit this run can reach, so the check run would land nowhere. Nothing was planned."
  fi
  # deploy-terragrunt.sh is reached by `exec`, so it reads both out of the environment.
  export PR_NUMBER HEAD_SHA
  tremvok::log "terragrunt-pull-request=#${PR_NUMBER} head=${HEAD_SHA:0:12}"

  # The tree is the caller's business: Tremvok never checks out a merge ref, and `ref:` on
  # their own actions/checkout is what decides what gets planned. But planning the default
  # branch's code against another pull request's file list is a silent wrong answer, so it is
  # at least said out loud. A warning and never a failure, because `checkout: false` with a
  # partial tree is a legitimate caller choice.
  if ! git cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null \
    || ! git merge-base --is-ancestor "$HEAD_SHA" HEAD 2>/dev/null; then
    tremvok::warn "the checked-out tree does not contain #${PR_NUMBER}'s head commit ${HEAD_SHA:0:12}, so the plan is of whatever is on disk. Check out refs/pull/${PR_NUMBER}/merge to plan what merging would produce."
  fi
fi

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
