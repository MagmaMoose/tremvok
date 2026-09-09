#!/usr/bin/env bash
# Put pinned, checksum-verified `tofu` and `terragrunt` binaries on PATH.
#
# Bootstrapped here rather than through a third-party setup action for the same reason the
# plan is saved: this step decides which binary applies to production, and a floating
# version is the one input nobody reviews. Two downloads and a checksum are cheaper than
# trusting a marketplace action with the same job.
#
# Cached on the runner rather than in $RUNNER_TEMP, which is wiped per job: re-fetching the
# archives cost close to two minutes on *every* run of the pipeline this is extracted from.
# The cache directory name pins both versions, so a bump lands in a new directory and can
# never pick up a stale binary, and every binary is checksum-verified before it is renamed
# into place. Staging inside the cache makes that final `mv` a same-filesystem rename, so a
# concurrent job sees either the old file or the complete new one, never a half-written
# binary.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

INSTALL="${INSTALL:-auto}"
TOFU_VERSION="${TOFU_VERSION:-}"
TG_VERSION="${TG_VERSION:-}"
PLUGIN_CACHE="${PLUGIN_CACHE:-}"
CACHE_ROOT="${TREMVOK_TOOL_CACHE:-${HOME}/.cache/tremvok-terragrunt}"
TOFU_BASE_URL="${TOFU_BASE_URL:-https://github.com/opentofu/opentofu/releases/download}"
TG_BASE_URL="${TG_BASE_URL:-https://github.com/gruntwork-io/terragrunt/releases/download}"

case "$INSTALL" in
  auto|always) ;;
  never) tremvok::log "terragrunt-install: never; using whatever the runner provides"; exit 0 ;;
  *) tremvok::fail "terragrunt-install must be auto, always or never (got '${INSTALL}')" ;;
esac

tremvok::require TOFU_VERSION "terragrunt-tofu-version"
tremvok::require TG_VERSION "terragrunt-version"

# The reference pipeline hardcoded linux_amd64. Derived here instead, so an arm64 runner
# gets an arm64 binary rather than an exec-format error twenty minutes into a plan.
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) tremvok::fail "no pinned tofu/terragrunt build for $(uname -m); set terragrunt-install: never and provide them yourself" ;;
esac

# `sha256sum` is GNU coreutils and absent on macOS, where the tool is `shasum -a 256`.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

verify() { # file  asset-name  sums-file
  local want got
  # `|| true` is load-bearing. With `pipefail` on, a grep that matches nothing makes the
  # whole pipeline non-zero, and a command substitution's status becomes the ASSIGNMENT's
  # status — so under `set -e` a missing checksum entry would exit the script silently,
  # right where the loudest possible failure is wanted.
  want="$(grep -E "([[:space:]]|/)$2\$" "$3" | awk '{print $1}' | head -1 || true)"
  [[ -n "$want" ]] || tremvok::fail "no checksum published for $2 — refusing to install an unverified binary"
  got="$(sha256_of "$1")"
  [[ "$want" == "$got" ]] || tremvok::fail "checksum mismatch for $2 (expected ${want}, got ${got})"
}

bin="${CACHE_ROOT}/tofu-${TOFU_VERSION}_tg-${TG_VERSION}_${os}_${arch}"
stage="${CACHE_ROOT}/.staging-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$$"
mkdir -p "$bin" "$stage"
trap 'rm -rf "$stage"' EXIT

# Existence is enough for a cache hit: nothing reaches $bin until it has been
# checksum-verified and renamed in whole, so a present file is a complete verified one.
# Tested with -s rather than -x, so a filesystem that does not carry the execute bit cannot
# silently turn every run back into a full download.
have() {
  [[ "$INSTALL" != "always" ]] || return 1
  [[ -s "${bin}/$1" ]] && return 0
  [[ "$INSTALL" == "auto" ]] && command -v "$1" >/dev/null 2>&1
}

if have tofu; then
  tremvok::log "tofu: cache hit"
else
  curl -fsSL --retry 3 -o "${stage}/tofu.zip" \
    "${TOFU_BASE_URL}/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_${os}_${arch}.zip"
  curl -fsSL --retry 3 -o "${stage}/tofu.sums" \
    "${TOFU_BASE_URL}/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_SHA256SUMS"
  verify "${stage}/tofu.zip" "tofu_${TOFU_VERSION}_${os}_${arch}.zip" "${stage}/tofu.sums"
  unzip -oq "${stage}/tofu.zip" tofu -d "$stage"
  chmod 0755 "${stage}/tofu"   # do not depend on the archive's mode bits
  mv -f "${stage}/tofu" "${bin}/tofu"
  tremvok::log "tofu ${TOFU_VERSION} installed"
fi

if have terragrunt; then
  tremvok::log "terragrunt: cache hit"
else
  curl -fsSL --retry 3 -o "${stage}/terragrunt" \
    "${TG_BASE_URL}/v${TG_VERSION}/terragrunt_${os}_${arch}"
  curl -fsSL --retry 3 -o "${stage}/tg.sums" "${TG_BASE_URL}/v${TG_VERSION}/SHA256SUMS"
  verify "${stage}/terragrunt" "terragrunt_${os}_${arch}" "${stage}/tg.sums"
  chmod 0755 "${stage}/terragrunt"
  mv -f "${stage}/terragrunt" "${bin}/terragrunt"
  tremvok::log "terragrunt ${TG_VERSION} installed"
fi

# Keep the live combination fresh and drop combinations nothing has used for a week, so a
# version bump cannot grow the cache forever and cannot delete a binary out from under a
# concurrent job.
touch "$bin"
find "$CACHE_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true

if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$bin" >>"$GITHUB_PATH"
fi

# Provider plugins persist across stacks and runs. The workspace is wiped on each checkout,
# so without this every stack re-downloads every provider — the single biggest cost in a
# multi-stack run, and the reason a five-stack plan took longer than the changes it found.
if [[ -n "$PLUGIN_CACHE" ]]; then
  # A leading `~` expanded by hand rather than by `eval`, which would run whatever a caller
  # put in the input. The default is a path with a tilde in it, so this is the common case,
  # not an edge one.
  plugin_cache="$PLUGIN_CACHE"
  # shellcheck disable=SC2088  # matching a LITERAL tilde is the point; it is unexpanded
  # input arriving from an action input, which is exactly what has to be handled here.
  case "$plugin_cache" in
    "~") plugin_cache="$HOME" ;;
    "~/"*) plugin_cache="${HOME}/${plugin_cache#\~/}" ;;
  esac
  mkdir -p "$plugin_cache"
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf 'TF_PLUGIN_CACHE_DIR=%s\n' "$plugin_cache" >>"$GITHUB_ENV"
  fi
  tremvok::log "provider plugin cache: ${plugin_cache}"
fi

PATH="${bin}:${PATH}" command -v tofu terragrunt >/dev/null \
  || tremvok::fail "tofu and terragrunt are not on PATH after bootstrap"
