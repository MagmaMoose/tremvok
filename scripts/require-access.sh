#!/usr/bin/env bash
# Refuse to publish docs to Cloudflare Pages unless an Access application already covers
# the hostname.
#
# Runs BEFORE the deploy, deliberately. A Pages project is served on the open internet at
# <project>.pages.dev by default, so "the repository is private" gates nothing: the moment
# content is uploaded it is public. Checking afterwards would be checking after the leak.
#
# This VERIFIES rather than creates. An API token with Pages:Edit typically has Access
# read but not Access write, so the application itself is created once by a human. What
# this guarantees is that nothing publishes until that has happened — and that an
# unreadable answer is a refusal, never an assumption that the site is gated.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

CF_TOKEN="${CF_TOKEN:-}"
CF_ACCOUNT="${CF_ACCOUNT:-}"
HOST_TO_CHECK="${HOST_TO_CHECK:-}"
CHECK="${CHECK:-$(dirname "${BASH_SOURCE[0]}")/access_covers.py}"
CF_API="${CF_API:-https://api.cloudflare.com/client/v4}"

[[ -n "$HOST_TO_CHECK" ]] || tremvok::fail "require-access needs a hostname to check"

resp="$(curl -sS -H "Authorization: Bearer ${CF_TOKEN}" \
  "${CF_API}/accounts/${CF_ACCOUNT}/access/apps?per_page=1000" 2>/dev/null || printf '')"
covered="$(printf '%s' "$resp" | python3 "$CHECK" "$HOST_TO_CHECK" 2>/dev/null || printf 'ERROR:unreadable')"

case "$covered" in
  YES)
    tremvok::log "Cloudflare Access covers ${HOST_TO_CHECK}; publishing."
    ;;
  NO)
    tremvok::fail "docs-require-access is set, but no Cloudflare Access application covers ${HOST_TO_CHECK}. A Pages project is public on the open internet by default, so publishing now would expose these docs. Create an Access application for that hostname (or a parent domain) and re-run."
    ;;
  ERROR:denied)
    tremvok::fail "cannot verify Cloudflare Access: the API token was refused. Refusing to publish rather than assuming the site is gated."
    ;;
  *)
    tremvok::fail "cannot verify Cloudflare Access (unreadable API response). Refusing to publish rather than assuming the site is gated."
    ;;
esac
