#!/usr/bin/env bash
# Work out how to build the docs, and where they are going, before anything is installed.
#
# Detection rather than declaration: `uv.lock` in the tree is the fact, and a caller
# restating it in config is one more thing that can disagree with the repo.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

REQUESTED="${REQUESTED:-auto}"
REQUIREMENTS="${REQUIREMENTS:-docs/requirements.txt}"
TARGET="${TARGET:-github-pages}"

case "$REQUESTED" in
  uv|pip) resolved="$REQUESTED" ;;
  auto)
    if [[ -f uv.lock ]]; then
      resolved=uv
    elif [[ -f "$REQUIREMENTS" ]]; then
      resolved=pip
    else
      tremvok::fail "no uv.lock and no ${REQUIREMENTS} — cannot tell how to install MkDocs. Set docs-toolchain explicitly."
    fi
    ;;
  *) tremvok::fail "docs-toolchain must be auto, uv or pip (got '${REQUESTED}')" ;;
esac

[[ -f mkdocs.yml ]] || tremvok::fail "no mkdocs.yml in ${PWD} — nothing to build."

case "$TARGET" in
  github-pages|none) ;;
  *) tremvok::fail "docs-target must be github-pages or none (got '${TARGET}')" ;;
esac

tremvok::set_output toolchain "$resolved"
tremvok::set_output target "$TARGET"
if [[ "$TARGET" == "github-pages" ]]; then
  tremvok::set_output stage-pages true
else
  tremvok::set_output stage-pages false
fi

# Node is preinstalled on GitHub-hosted runners but NOT on a self-hosted one, where `npx`
# is absent and the markdown lint died with exit 127 rather than skipping or installing.
if command -v npx >/dev/null 2>&1; then
  tremvok::set_output has-node true
else
  tremvok::set_output has-node false
fi

tremvok::summary "Toolchain: ${resolved} | docs-target: ${TARGET}"
tremvok::log "toolchain=${resolved} docs-target=${TARGET}"
