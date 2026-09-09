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
MODE="${MODE:-deploy}"
DRY_RUN="${DRY_RUN:-false}"

case "$REQUESTED" in
  uv|pip) resolved="$REQUESTED" ;;
  auto)
    if [[ -f uv.lock ]]; then
      resolved=uv
    elif [[ -f "$REQUIREMENTS" ]]; then
      resolved=pip
    else
      tremvok::fail "no uv.lock and no ${REQUIREMENTS} — cannot tell how to install MkDocs. Set pages-toolchain explicitly."
    fi
    ;;
  *) tremvok::fail "pages-toolchain must be auto, uv or pip (got '${REQUESTED}')" ;;
esac

[[ -f mkdocs.yml ]] || tremvok::fail "no mkdocs.yml in ${PWD} — nothing to build."

# GitHub Pages has no preview destination: there is one site and publishing to it is
# publishing. So a pull request builds and checks without staging an artifact, which is what
# `mode: preview` already means everywhere else, and a dry run does the same. That is why
# this target needs no destination input of its own.
stage=true
if tremvok::is_true "$DRY_RUN" || [[ "$MODE" == "preview" ]]; then
  stage=false
fi

tremvok::set_output toolchain "$resolved"
tremvok::set_output stage-pages "$stage"

# Node is preinstalled on GitHub-hosted runners but NOT on a self-hosted one, where `npx`
# is absent and the markdown lint died with exit 127 rather than skipping or installing.
if command -v npx >/dev/null 2>&1; then
  tremvok::set_output has-node true
else
  tremvok::set_output has-node false
fi

tremvok::summary "Toolchain: ${resolved} | staging a Pages artifact: ${stage}"
tremvok::log "toolchain=${resolved} mode=${MODE} stage-pages=${stage}"
