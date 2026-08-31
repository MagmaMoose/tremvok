#!/usr/bin/env bash
# Plan or apply one Terragrunt stack, buffered, redacted, and with a status file.
#
# Output is buffered to a file rather than streamed because a plan is long, several stacks run
# in sequence, and the interesting part is the last forty lines. Buffering it also means it can
# be redacted before it reaches a pull-request comment.
#
# The exit code and the status file say different things on purpose:
#   status=no-changes  planned clean
#   status=changes     planned with a diff
#   status=failed      the tool errored
# A caller that only reads the exit code cannot tell "nothing to do" from "something to do",
# and that difference is what decides whether a pull request needs an apply before it merges.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

action="${1:-plan}"

TG_BIN="${TG_BIN:-terragrunt}"
EXTRA_ARGS="${EXTRA_ARGS:-}"

# Redact before anything is shown. Terraform marks its own sensitive outputs, but a provider
# can print a token in an error message and a pull-request comment is world-readable on a
# public repository. Matches `name = "value"` where the name looks like a credential.
redact() {
  sed -E \
    -e 's/((password|secret|token|api_key|access_key|private_key|client_secret)[a-z_]*[[:space:]]*=[[:space:]]*)"[^"]*"/\1"***"/gI' \
    -e 's/(AKIA|ASIA)[A-Z0-9]{16}/\1****************/g' \
    -e 's#(https?://)[^/@[:space:]]+:[^/@[:space:]]+@#\1***:***@#g'
}

# Handled before the plan/apply argument checks: `redact` takes a file, not a stack.
if [[ "$action" == "redact" ]]; then
  redact <"${2:-/dev/stdin}"
  exit 0
fi

stack="${2:-}"
out_dir="${3:-}"
[[ -n "$stack" ]] || tremvok::fail "usage: terragrunt-run.sh plan|apply <stack> <output-dir>"
[[ -n "$out_dir" ]] || tremvok::fail "usage: terragrunt-run.sh plan|apply <stack> <output-dir>"
mkdir -p "$out_dir"

run() { # log-file  args...
  local log="$1"; shift
  # `set +e` around the tool: a failing plan is a result to report, not a reason to abandon the
  # remaining stacks. `pipefail` is still on, so `| tee` cannot mask the tool's exit code —
  # which is precisely the bug dunmir documented paying for.
  set +e
  ( cd "$stack" && "$TG_BIN" "$@" ) >"$log" 2>&1
  local code=$?
  set -e
  return $code
}

# shellcheck disable=SC2206  # deliberate word splitting: EXTRA_ARGS is a flag string
extra=( $EXTRA_ARGS )

case "$action" in
  plan)
    if run "${out_dir}/init.txt" init -input=false -upgrade=false; then
      set +e
      ( cd "$stack" && "$TG_BIN" plan -input=false -lock-timeout=5m -detailed-exitcode \
          ${extra[@]+"${extra[@]}"} ) >"${out_dir}/plan.txt" 2>&1
      code=$?
      set -e
      # `-detailed-exitcode`: 0 no changes, 2 changes, anything else an error. Without it the
      # only way to tell "nothing to do" from "a diff" is to parse English out of the output.
      case $code in
        0) printf 'no-changes\n' >"${out_dir}/status"; exit 0 ;;
        2) printf 'changes\n' >"${out_dir}/status"; exit 0 ;;
        *) printf 'failed\n' >"${out_dir}/status"; exit "$code" ;;
      esac
    else
      printf 'failed\n' >"${out_dir}/status"
      exit 1
    fi
    ;;
  apply)
    if run "${out_dir}/init.txt" init -input=false -upgrade=false \
      && run "${out_dir}/apply.txt" apply -input=false -auto-approve -lock-timeout=5m \
           ${extra[@]+"${extra[@]}"}; then
      printf 'applied\n' >"${out_dir}/status"
      exit 0
    fi
    printf 'failed\n' >"${out_dir}/status"
    exit 1
    ;;
  *)
    tremvok::fail "unknown action '${action}' (expected plan, apply or redact)"
    ;;
esac
