#!/usr/bin/env bash
# Ship a built static site to S3 and invalidate CloudFront.
#
# The two failures this file is shaped around:
#
#   1. `aws s3 sync --delete` against an empty or wrong directory **empties the site**. A build
#      that failed quietly and left `dist/` empty turns a deploy into an outage, and the sync
#      exits 0 while doing it. So the source is checked before anything is synced, and the
#      check is a refusal, not a warning.
#   2. Objects in the bucket are not the same thing as bytes on the edge. The invalidation is
#      part of the deploy, not an afterthought, and `verify-live.sh` is what actually proves
#      the new version is being served.
#
# Cache headers are set here rather than in the bucket because they differ per object class:
# fingerprinted assets are immutable for a year, HTML must never be, and getting that backwards
# is either a stale site or a CDN that does nothing.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

BUCKET="${BUCKET:-}"
ARTIFACT_PATH="${ARTIFACT_PATH:-}"
KEY_PREFIX="${KEY_PREFIX:-}"
MODE="${MODE:-deploy}"
PREVIEW_ALIAS="${PREVIEW_ALIAS:-}"
PREVIEW_PREFIX="${PREVIEW_PREFIX:-previews}"
DISTRIBUTION_ID="${DISTRIBUTION_ID:-}"
SITE_URL="${SITE_URL:-}"
DELETE_ORPHANS="${DELETE_ORPHANS:-auto}"
CACHE_CONTROL_ASSETS="${CACHE_CONTROL_ASSETS:-public, max-age=31536000, immutable}"
CACHE_CONTROL_DOCUMENTS="${CACHE_CONTROL_DOCUMENTS:-public, max-age=0, must-revalidate}"
INVALIDATION_PATHS="${INVALIDATION_PATHS:-}"
DRY_RUN="${DRY_RUN:-false}"

tremvok::require BUCKET "the S3 bucket serving the site"
tremvok::require ARTIFACT_PATH "the directory your build produced"

[[ -d "$ARTIFACT_PATH" ]] || tremvok::fail "artifact-path '${ARTIFACT_PATH}' is not a directory"
# The guard. `find -type f -print -quit` stops at the first file, so this stays instant on a
# large site, and it catches the empty *and* the only-empty-directories cases together.
if [[ -z "$(find "$ARTIFACT_PATH" -type f -print -quit)" ]]; then
  tremvok::fail "artifact-path '${ARTIFACT_PATH}' contains no files. Refusing to sync: with --delete this would empty the site, and without it this deploy would do nothing. Check that the build step actually ran."
fi

# Where in the bucket this lands. A preview goes under its own prefix so it cannot touch
# production objects, and so deleting the whole preview later is one `rm --recursive`.
destination_prefix="$KEY_PREFIX"
case "$MODE" in
  preview)
    [[ -n "$PREVIEW_ALIAS" ]] || tremvok::fail "preview mode needs a preview-alias"
    destination_prefix="${KEY_PREFIX:+${KEY_PREFIX%/}/}${PREVIEW_PREFIX%/}/${PREVIEW_ALIAS}"
    ;;
  deploy|rollback) ;;
  *) tremvok::fail "unsupported mode '${MODE}' for target s3-cloudfront" ;;
esac
destination_prefix="${destination_prefix#/}"
destination="s3://${BUCKET}${destination_prefix:+/${destination_prefix}}"

# `--delete` removes bucket objects with no local counterpart. Right for a production sync
# (orphaned assets otherwise accumulate forever) and right for a preview too, since the whole
# prefix belongs to one pull request. `auto` exists so a repository sharing a bucket prefix
# with something else can turn it off.
sync_flags=()
if [[ "$DELETE_ORPHANS" == "auto" ]] || tremvok::is_true "$DELETE_ORPHANS"; then
  sync_flags+=(--delete)
fi

run_aws() {
  if tremvok::is_true "$DRY_RUN"; then
    tremvok::log "DRY RUN: aws $*"
    return 0
  fi
  aws "$@"
}

tremvok::log "syncing ${ARTIFACT_PATH} -> ${destination}"

# Two passes. The first uploads everything with the immutable header and excludes the document
# types; the second re-uploads only the documents with a revalidating header. Ordering matters:
# documents reference the assets, so an asset must never be missing while its HTML is live.
run_aws s3 sync "$ARTIFACT_PATH" "$destination" \
  ${sync_flags[@]+"${sync_flags[@]}"} \
  --no-progress \
  --cache-control "$CACHE_CONTROL_ASSETS" \
  --exclude '*.html' --exclude '*.json' --exclude '*.xml' --exclude '*.txt' --exclude '*.md'

run_aws s3 sync "$ARTIFACT_PATH" "$destination" \
  --no-progress \
  --cache-control "$CACHE_CONTROL_DOCUMENTS" \
  --exclude '*' \
  --include '*.html' --include '*.json' --include '*.xml' --include '*.txt' --include '*.md'

invalidation_id=""
if [[ -n "$DISTRIBUTION_ID" ]]; then
  paths="$INVALIDATION_PATHS"
  if [[ -z "$paths" ]]; then
    paths=$([[ -n "$destination_prefix" ]] && printf '/%s/*' "$destination_prefix" || printf '/*')
  fi
  tremvok::log "invalidating ${paths} on ${DISTRIBUTION_ID}"
  if tremvok::is_true "$DRY_RUN"; then
    tremvok::log "DRY RUN: aws cloudfront create-invalidation --distribution-id ${DISTRIBUTION_ID} --paths ${paths}"
  else
    # 1,000 invalidation paths a month are free and every path after that is billed, so this
    # sends one wildcard rather than one entry per changed file. read -ra splits a
    # space-separated list into the several --paths arguments the CLI expects.
    read -ra path_list <<<"$paths"
    invalidation_id="$(aws cloudfront create-invalidation \
      --distribution-id "$DISTRIBUTION_ID" \
      --paths "${path_list[@]}" \
      --query 'Invalidation.Id' --output text)"
    tremvok::log "invalidation ${invalidation_id}"
  fi
else
  tremvok::warn "no distribution-id set: objects are updated in S3 but the CDN will keep serving the old ones until its TTL expires."
fi

# The URL a human should open. Preview URLs are the site URL plus the preview prefix, which
# assumes the distribution serves the whole bucket; a repository whose previews live on a
# different hostname sets site-url per environment instead.
url=""
if [[ -n "$SITE_URL" ]]; then
  base="${SITE_URL%/}"
  if [[ "$MODE" == "preview" ]]; then
    url="${base}/${PREVIEW_PREFIX%/}/${PREVIEW_ALIAS}/"
  else
    url="${base}/"
  fi
fi

tremvok::set_output url "$url"
tremvok::set_output destination "$destination"
tremvok::set_output invalidation-id "$invalidation_id"
tremvok::set_output deployed "true"
