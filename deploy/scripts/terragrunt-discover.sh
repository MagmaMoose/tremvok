#!/usr/bin/env bash
# Map a set of changed files to the Terragrunt stacks they affect.
#
# A "stack" is a directory containing `terragrunt.hcl` that is not the repository's root
# configuration and not a shared module. Two modes:
#
#   all             every stack under ROOT_DIR (the scheduled drift run, and manual full runs)
#   changed <file>  only the stacks that own a changed path
#
# Changed-file mapping walks *up* from each changed path to the nearest enclosing stack, so
# editing a file three directories inside a stack still finds it. A change under `modules/`
# maps to nothing on purpose: a module has no state of its own, and guessing which stacks use
# it from a path is how a "small module tidy-up" ends up planning the entire estate.
set -euo pipefail
# shellcheck source=deploy/scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ROOT_DIR="${ROOT_DIR:-terraform}"
# Directory names that hold shared code rather than a stack. Matched as a whole path segment.
EXCLUDE_SEGMENTS="${EXCLUDE_SEGMENTS:-modules _modules .terragrunt-cache .terraform}"

mode="${1:-all}"
changed_file="${2:-}"

is_excluded() {
  local path="$1" segment
  for segment in $EXCLUDE_SEGMENTS; do
    case "/${path}/" in
      */"${segment}"/*) return 0 ;;
    esac
  done
  return 1
}

# A stack is a directory with terragrunt.hcl in it. `root.hcl` / `terragrunt.hcl` at the very
# top of ROOT_DIR is the shared include, not a stack, so ROOT_DIR itself never qualifies.
is_stack() {
  local dir="$1"
  [[ "$dir" == "$ROOT_DIR" || "$dir" == "." ]] && return 1
  is_excluded "$dir" && return 1
  [[ -f "${dir}/terragrunt.hcl" ]]
}

all_stacks() {
  [[ -d "$ROOT_DIR" ]] || return 0
  # `if` rather than `is_stack && printf`: under `set -e` with `pipefail`, a loop whose LAST
  # iteration hits an excluded directory exits non-zero, which fails the whole pipeline. The
  # symptom is discovery working until somebody adds a module that sorts last.
  find "$ROOT_DIR" -name terragrunt.hcl -type f 2>/dev/null \
    | while read -r hcl; do
        dir="$(dirname "$hcl")"
        if is_stack "$dir"; then printf '%s\n' "$dir"; fi
      done \
    | sort -u
}

changed_stacks() {
  [[ -n "$changed_file" && -f "$changed_file" ]] || tremvok::fail "discover changed needs a file of changed paths"
  while read -r path; do
    [[ -n "$path" ]] || continue
    dir="$(dirname "$path")"
    # Walk up until a stack is found or the tree runs out. A deleted file's directory may no
    # longer exist, which is why this tests for terragrunt.hcl rather than for the directory.
    while [[ "$dir" != "." && "$dir" != "/" ]]; do
      if is_stack "$dir"; then
        printf '%s\n' "$dir"
        break
      fi
      dir="$(dirname "$dir")"
    done
    # Same pipefail trap as above: the inner loop ends non-zero whenever a path walked all the
    # way up without finding a stack, which is the normal case for an unrelated file.
    :
  done <"$changed_file" | sort -u
}

case "$mode" in
  all) all_stacks ;;
  changed) changed_stacks ;;
  *) tremvok::fail "usage: terragrunt-discover.sh all|changed [changed-files-file]" ;;
esac
