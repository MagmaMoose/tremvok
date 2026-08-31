#!/usr/bin/env bash
# Decide whether this run can deploy at all, and skip *loudly* when it cannot.
#
# Two situations produce a confusing red job in every hand-rolled deploy workflow in the fleet:
#
#   * a pull request from a fork, which cannot read secrets — so the AWS credential is empty
#     and the deploy fails with an authentication error that looks like a broken credential
#     rather than a policy that is working as designed;
#   * a repository that has adopted the workflow but not yet been wired to a role, where the
#     same thing happens for a different reason.
#
# Both are expected states, so both become a skip with a reason on the job summary. dunmir's
# planner does this for Cloudflare; this is that generalised, because "honest skip over
# confusing failure" only works if it covers every reason to skip.
set -euo pipefail
# shellcheck source=deploy/scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

IS_FORK="${IS_FORK:-false}"
ROLE_TO_ASSUME="${ROLE_TO_ASSUME:-}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_WEB_IDENTITY_TOKEN_FILE="${AWS_WEB_IDENTITY_TOKEN_FILE:-}"
TARGET="${TARGET:-}"
ALLOW_FORK_PREVIEW="${ALLOW_FORK_PREVIEW:-false}"

skip=false
reason=""

if tremvok::is_true "$IS_FORK" && ! tremvok::is_true "$ALLOW_FORK_PREVIEW"; then
  skip=true
  reason="this pull request comes from a fork, so the workflow cannot read the deployment credential. Nothing was deployed, and that is the intended behaviour — a fork must not be able to publish."
elif [[ -z "$ROLE_TO_ASSUME" && -z "$AWS_ACCESS_KEY_ID" && -z "$AWS_WEB_IDENTITY_TOKEN_FILE" ]]; then
  skip=true
  reason="no AWS credential is available: set role-to-assume (OIDC, preferred) or configure credentials in an earlier step. Nothing was deployed."
fi

if [[ "$skip" == true ]]; then
  tremvok::notice "Tremvok skipped: ${reason}"
  tremvok::summary "## Tremvok — skipped"
  tremvok::summary ""
  tremvok::summary "${reason}"
else
  tremvok::log "preflight ok for target=${TARGET:-<unset>}"
fi

tremvok::set_output skip "$skip"
tremvok::set_output skip-reason "$reason"
