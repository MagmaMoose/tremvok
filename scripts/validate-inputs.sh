#!/usr/bin/env bash
# Refuse a run whose inputs do not belong to its target.
#
# This is the answer to the objection against a target enum: "a mode enum where most
# values error is a listing that cannot say what it does". It is only a fair objection if
# the inapplicable inputs are *silently ignored*. Here they are a hard error naming the
# target, before the checkout, so `target: ansible` with `s3-bucket` set is reported as
# the mistake it is rather than deploying nothing to a bucket nobody looks at.
#
# Applicability comes from scripts/lib/input-targets.json, generated from action.yml's own
# descriptions by scripts/gen_input_targets.py. jq rather than a YAML parser because jq is
# on every runner and PyYAML is not.
#
# The one thing this cannot see: an input set explicitly to the value it already defaults
# to. GitHub gives a composite action no way to tell "unset" from "set to the default", and
# an input holding its default value changes nothing, so the blind spot is harmless.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${here}/lib/common.sh"

TARGET="${TARGET:-}"
INPUTS_JSON="${INPUTS_JSON:-}"
# Two lines rather than an inline default, because every brace form of it is wrong in a way
# that only shows up half the time. `${X:-{}}` closes the expansion at the FIRST `}`, so a
# SET value silently gains a trailing `}` and jq rejects it, while an unset one still yields
# `{}` and looks correct. `${X:-\{\}}` is worse: backslash is literal inside double quotes,
# so the default becomes the 3-character string `\{}`.
[[ -n "$INPUTS_JSON" ]] || INPUTS_JSON='{}'
MAP="${INPUT_TARGETS_MAP:-${here}/lib/input-targets.json}"

[[ -f "$MAP" ]] || tremvok::fail "input applicability map is missing at ${MAP}"

known="$(jq -r '.targets | join(", ")' "$MAP")"
if [[ -z "$TARGET" ]]; then
  tremvok::fail "target is required. One of: ${known}."
fi
if ! jq -e --arg t "$TARGET" '.targets | index($t)' "$MAP" >/dev/null; then
  tremvok::fail "unknown target '${TARGET}'. One of: ${known}."
fi

# One jq program, so the whole input set is reported at once. A caller who mixed up two
# targets should see both mistakes on the first run, not one per attempt.
violations="$(
  jq -r --arg target "$TARGET" --argjson given "$INPUTS_JSON" '
    .inputs
    | to_entries
    | map(select((($given[.key] // .value.default) | tostring) != (.value.default | tostring)))
    | map(select((.value.targets | index($target)) == null))
    | .[]
    | "\(.key)\t\(.value.targets | join(", "))"
  ' "$MAP"
)"

if [[ -n "$violations" ]]; then
  tremvok::error "these inputs do not apply to target: ${TARGET}"
  while IFS="$(printf '\t')" read -r name applies; do
    [[ -n "$name" ]] || continue
    tremvok::error "  ${name} — only valid for target: ${applies}"
  done <<<"$violations"
  tremvok::summary "## Tremvok — inputs do not match the target"
  tremvok::summary ""
  tremvok::summary "\`target: ${TARGET}\` was selected, but these inputs belong to another target:"
  tremvok::summary ""
  tremvok::summary "| Input | Applies to |"
  tremvok::summary "|:--|:--|"
  while IFS="$(printf '\t')" read -r name applies; do
    [[ -n "$name" ]] || continue
    tremvok::summary "| \`${name}\` | \`${applies}\` |"
  done <<<"$violations"
  exit 1
fi

tremvok::log "inputs validated for target=${TARGET}"
