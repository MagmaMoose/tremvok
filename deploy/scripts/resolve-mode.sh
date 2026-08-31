#!/usr/bin/env bash
# Derive what this run should do from the event that triggered it.
#
#   push to the default branch   -> deploy      (publish to the environment)
#   pull_request                 -> preview     (publish somewhere disposable)
#   workflow_dispatch            -> deploy      (a re-publish; the rollback path)
#
# The rule worth stating out loud: a `workflow_dispatch` run is pinned to the default branch.
# Without that, "Run workflow" from a topic branch quietly publishes that branch to production
# — which looks like a deploy, is recorded as one, and nobody notices until the next real
# release reverts it.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MODE="${MODE:-auto}"
EVENT_NAME="${EVENT_NAME:-}"
REF="${REF:-}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
PR_NUMBER="${PR_NUMBER:-}"
ENVIRONMENT="${ENVIRONMENT:-}"
PREVIEW_ALIAS="${PREVIEW_ALIAS:-}"
ALLOW_DISPATCH_FROM_ANY_REF="${ALLOW_DISPATCH_FROM_ANY_REF:-false}"

resolved="$MODE"

if [[ "$MODE" == "auto" ]]; then
  case "$EVENT_NAME" in
    pull_request|pull_request_target)
      resolved="preview"
      ;;
    push)
      if [[ "$REF" != "refs/heads/${DEFAULT_BRANCH}" ]]; then
        tremvok::fail "mode: auto on a push to ${REF}; only refs/heads/${DEFAULT_BRANCH} deploys. Set mode explicitly to override."
      fi
      resolved="deploy"
      ;;
    workflow_dispatch|repository_dispatch)
      if [[ "$REF" != "refs/heads/${DEFAULT_BRANCH}" ]] && ! tremvok::is_true "$ALLOW_DISPATCH_FROM_ANY_REF"; then
        tremvok::fail "a manual run must start from ${DEFAULT_BRANCH}; this one selected ${REF}. Publishing a topic branch to an environment is almost never what was meant — set allow-dispatch-from-any-ref: true if it is."
      fi
      resolved="deploy"
      ;;
    release)
      resolved="deploy"
      ;;
    *)
      tremvok::fail "mode: auto cannot derive a mode from a '${EVENT_NAME}' event. Set mode to deploy or preview."
      ;;
  esac
fi

case "$resolved" in
  deploy|preview|rollback) ;;
  *) tremvok::fail "unknown mode '${resolved}' (expected auto, deploy, preview or rollback)" ;;
esac

# A preview needs somewhere disposable to live. `pr-<N>` is stable across pushes to the same
# pull request, which is what keeps one sticky comment pointing at one URL.
alias_value="$PREVIEW_ALIAS"
if [[ "$resolved" == "preview" && -z "$alias_value" ]]; then
  [[ -n "$PR_NUMBER" ]] || tremvok::fail "preview mode needs a pull-request number or an explicit preview-alias"
  alias_value="pr-${PR_NUMBER}"
fi
alias_value="$(tremvok::slug "$alias_value")"

environment="$ENVIRONMENT"
if [[ -z "$environment" ]]; then
  environment=$([[ "$resolved" == "preview" ]] && printf 'preview' || printf 'production')
fi

tremvok::set_output mode "$resolved"
tremvok::set_output environment "$environment"
tremvok::set_output preview-alias "$alias_value"
tremvok::log "mode=${resolved} environment=${environment} preview-alias=${alias_value:-<none>}"
