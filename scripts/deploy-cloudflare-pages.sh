#!/usr/bin/env bash
# Publish a built site to Cloudflare Pages.
#
# Idempotent by design: creating a project that already exists is not a failure worth
# stopping for, and that is what lets a brand-new repository publish with no manual
# Cloudflare setup at all. Detecting first by parsing `project list` was the previous
# approach and it broke twice — the output is a table, so a whole-line grep never matched,
# and every run then tried to create a project that existed and failed the deploy.
# Attempting the create and reading the error is the honest version; anything OTHER than
# already-exists still fails loudly.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

PROJECT="${PROJECT:-}"
SITE_DIR="${SITE_DIR:-site}"
BRANCH="${BRANCH:-}"
DRY_RUN="${DRY_RUN:-false}"
WRANGLER="${WRANGLER:-npx --yes wrangler@4.20.0}"

tremvok::require PROJECT "the Cloudflare Pages project name"
[[ -d "$SITE_DIR" ]] || tremvok::fail "no built site at ${SITE_DIR}"

branch="${BRANCH:-${GITHUB_REF_NAME:-main}}"
canonical="https://${PROJECT}.pages.dev"

if tremvok::is_true "$DRY_RUN"; then
  tremvok::log "DRY RUN: would deploy ${SITE_DIR} to Cloudflare Pages project ${PROJECT} on branch ${branch}"
  tremvok::set_output page-url "$canonical"
  tremvok::set_output deployment-url ""
  exit 0
fi

create_log="$(mktemp)"
if ! $WRANGLER pages project create "$PROJECT" --production-branch main >"$create_log" 2>&1; then
  if grep -qiE 'already exists|8000002' "$create_log"; then
    tremvok::log "Cloudflare Pages project ${PROJECT} already exists; deploying to it."
  else
    tremvok::error "could not create Cloudflare Pages project ${PROJECT}"
    cat "$create_log" >&2
    rm -f "$create_log"
    exit 1
  fi
fi
rm -f "$create_log"

deploy_log="$(mktemp)"
# `pipefail` is set, so `| tee` cannot mask wrangler's exit code — the failure mode this
# repository exists to avoid.
$WRANGLER pages deploy "$SITE_DIR" \
  --project-name "$PROJECT" --branch "$branch" --commit-dirty=true 2>&1 | tee "$deploy_log"

# wrangler reports the DEPLOYMENT url (<hash>.<project>.pages.dev). Report the CANONICAL
# one as well: the hashed host is per-deployment and is not what anyone links to, and on a
# brand-new project it resolves later than the project host.
deployed="$(grep -oE 'https://[a-z0-9.-]+[.]pages[.]dev' "$deploy_log" | tail -1 || true)"
rm -f "$deploy_log"

tremvok::set_output page-url "$canonical"
tremvok::set_output deployment-url "$deployed"
tremvok::summary "Deployed **${PROJECT}**"
tremvok::summary ""
tremvok::summary "- site: ${canonical}"
[[ -n "$deployed" ]] && tremvok::summary "- this deployment: ${deployed}"
exit 0
