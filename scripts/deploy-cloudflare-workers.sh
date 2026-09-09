#!/usr/bin/env bash
# The Cloudflare Workers target: publish a Worker and its static assets with Wrangler.
#
# Workers rather than Pages. Cloudflare's current guidance puts new projects on Workers
# static assets, which is where the ongoing investment goes, and an assets-only Worker (no
# entry point) serves files straight from the edge: no cold start, no code in the request
# path, and asset requests are not billed as invocations.
#
# The mode split is the whole reason this fits Tremvok's shape rather than needing its own
# vocabulary:
#
#   deploy   `wrangler deploy`                 live on the configured routes
#   preview  `wrangler versions upload`        uploaded, reachable on its own alias URL,
#            with --preview-alias              taking NO production traffic
#
# `preview-alias` comes from resolve-mode.sh and is `pr-<N>`, so the link in a pull-request
# comment is stable across pushes. A branch name would not be: it changes, and it is not
# always URL-safe.
#
# The Wrangler config file stays authoritative for asset directory, routes, custom domains
# and 404 handling. The inputs here are overrides for the few things a workflow legitimately
# varies between runs, and everything else is deliberately left to the config so that what
# is deployed matches what is reviewed in the repository.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MODE="${MODE:-deploy}"
PREVIEW_ALIAS="${PREVIEW_ALIAS:-}"
CONFIG="${CONFIG:-}"
WORKER_NAME="${WORKER_NAME:-}"
CF_ENV="${CF_ENV:-}"
MAIN="${MAIN:-}"
ASSETS="${ASSETS:-}"
BUILD_COMMAND="${BUILD_COMMAND:-}"
COMPATIBILITY_DATE="${COMPATIBILITY_DATE:-}"
MINIFY="${MINIFY:-false}"
VARS="${VARS:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
WRANGLER_VERSION="${WRANGLER_VERSION:-}"
DRY_RUN="${DRY_RUN:-false}"
# Overridable so bats can put a recorder in front of it; production always uses npx with a
# pinned version rather than whatever `wrangler` happens to be on PATH.
WRANGLER_BIN="${WRANGLER_BIN:-}"

tremvok::require CLOUDFLARE_API_TOKEN "cloudflare-api-token"
tremvok::require CLOUDFLARE_ACCOUNT_ID "cloudflare-account-id"

if [[ -z "$WRANGLER_BIN" ]]; then
  tremvok::require WRANGLER_VERSION "cloudflare-wrangler-version"
  WRANGLER_BIN="npx --yes wrangler@${WRANGLER_VERSION}"
fi

if [[ -n "$BUILD_COMMAND" ]]; then
  tremvok::log "building: ${BUILD_COMMAND}"
  # Deliberately word-split: this is a command line supplied by the caller.
  # shellcheck disable=SC2086
  eval "$BUILD_COMMAND"
fi

# After the build, not before: `cloudflare-build-command` is there for a Worker that needs
# bundling, and bundling is what creates the asset directory. Checking first would refuse
# every Worker that builds its own assets, and checking after is strictly stronger anyway —
# it now catches the build that ran and produced nothing, which is the same failure the S3
# target refuses: an empty directory published over a site that was working.
if [[ -n "$ASSETS" ]]; then
  [[ -d "$ASSETS" ]] || tremvok::fail "artifact-path '${ASSETS}' is not a directory"
  if [[ -z "$(find "$ASSETS" -type f -print -quit 2>/dev/null)" ]]; then
    tremvok::fail "artifact-path '${ASSETS}' has no files in it. Refusing to publish an empty asset directory over a site that is currently serving."
  fi
fi

args=()
[[ -n "$CONFIG" ]] && args+=( --config "$CONFIG" )
[[ -n "$WORKER_NAME" ]] && args+=( --name "$WORKER_NAME" )
[[ -n "$CF_ENV" ]] && args+=( --env "$CF_ENV" )
[[ -n "$ASSETS" ]] && args+=( --assets "$ASSETS" )
[[ -n "$COMPATIBILITY_DATE" ]] && args+=( --compatibility-date "$COMPATIBILITY_DATE" )
tremvok::is_true "$MINIFY" && args+=( --minify )

# One `--var` per line. `while read` rather than mapfile, which is bash 4.
while IFS= read -r pair; do
  [[ -n "$pair" ]] || continue
  args+=( --var "$pair" )
done <<<"$VARS"

# shellcheck disable=SC2206  # deliberate word splitting: EXTRA_ARGS is a flag string
extra=( $EXTRA_ARGS )

case "$MODE" in
  deploy)
    verb=( deploy )
    ;;
  preview)
    [[ -n "$PREVIEW_ALIAS" ]] || tremvok::fail "preview mode needs a preview-alias"
    # `versions upload` uploads WITHOUT deploying: the version gets its own URL and takes no
    # production traffic. `deploy` would put a pull request straight onto the live routes.
    verb=( versions upload --preview-alias "$PREVIEW_ALIAS" )
    ;;
  *)
    tremvok::fail "unsupported mode '${MODE}' for target cloudflare-workers (expected deploy or preview)"
    ;;
esac

# The positional entry point goes last, after the flags, and only when there is one. An
# assets-only Worker has no entry point at all, and passing an empty string would make
# Wrangler read the current directory as the script path.
positional=()
[[ -n "$MAIN" ]] && positional+=( "$MAIN" )

if tremvok::is_true "$DRY_RUN"; then
  tremvok::log "DRY RUN: ${WRANGLER_BIN} ${verb[*]} ${args[*]-} ${positional[*]-}"
  tremvok::set_output deployed false
  tremvok::set_output url ""
  tremvok::set_output version-id ""
  exit 0
fi

log_file="${RUNNER_TEMP:-/tmp}/tremvok-wrangler.log"
code=0
# `pipefail` is set, so `| tee` cannot report tee's exit code in place of Wrangler's, which
# is the failure this repository exists to stop repeating.
# shellcheck disable=SC2086  # WRANGLER_BIN is a command prefix (`npx --yes wrangler@x`)
$WRANGLER_BIN "${verb[@]}" ${args[@]+"${args[@]}"} ${extra[@]+"${extra[@]}"} \
  ${positional[@]+"${positional[@]}"} 2>&1 | tee "$log_file" || code=$?

if (( code != 0 )); then
  tremvok::set_output deployed false
  tremvok::fail "wrangler exited ${code}"
fi

# Wrangler prints the URL it published to and, for an upload, the version id. Parsed rather
# than assumed: a preview URL is per-alias and a deploy URL comes from the config's routes,
# so neither can be constructed here without duplicating the config.
url="$(grep -oE 'https://[A-Za-z0-9._-]+\.workers\.dev[A-Za-z0-9._/-]*' "$log_file" | tail -1 || true)"
if [[ -z "$url" ]]; then
  url="$(grep -oE 'https://[A-Za-z0-9._-]+\.[A-Za-z]{2,}[A-Za-z0-9._/-]*' "$log_file" | tail -1 || true)"
fi
version_id="$(grep -oiE 'version id:?[[:space:]]*[0-9a-f-]{8,}' "$log_file" | tail -1 | grep -oE '[0-9a-f-]{8,}$' || true)"
rm -f "$log_file"

tremvok::set_output deployed true
tremvok::set_output url "$url"
tremvok::set_output version-id "$version_id"

tremvok::summary "## Cloudflare Workers — ${MODE}"
tremvok::summary ""
tremvok::summary "| | |"
tremvok::summary "|:--|:--|"
[[ -n "$WORKER_NAME" ]] && tremvok::summary "| Worker | \`${WORKER_NAME}\` |"
[[ -n "$url" ]] && tremvok::summary "| URL | ${url} |"
[[ -n "$version_id" ]] && tremvok::summary "| Version | \`${version_id}\` |"
[[ "$MODE" == "preview" ]] && tremvok::summary "| Preview alias | \`${PREVIEW_ALIAS}\` |"
tremvok::log "wrangler ${MODE} complete${url:+ -> $url}"
exit 0
