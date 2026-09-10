#!/usr/bin/env bash
# Test harness for the shell scripts.
#
# Every test runs with a scratch $GITHUB_OUTPUT and a stub `bin/` at the front of $PATH, so a
# script that reaches for `aws` or `curl` gets a recorder instead of the real thing. That is
# what makes it possible to assert on the exact command line a deploy would have run —
# including the flags that only matter when they are wrong, like `--delete`.

setup_common() {
  export TREMVOK_ROOT
  TREMVOK_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export SCRIPTS="${TREMVOK_ROOT}/scripts"

  export WORK="${BATS_TEST_TMPDIR}"
  export GITHUB_OUTPUT="${WORK}/outputs.txt"
  export GITHUB_STEP_SUMMARY="${WORK}/summary.md"
  export GITHUB_ENV="${WORK}/env.txt"
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_STEP_SUMMARY"
  : >"$GITHUB_ENV"

  export STUB_BIN="${WORK}/bin"
  export STUB_LOG="${WORK}/calls.log"
  mkdir -p "$STUB_BIN"
  : >"$STUB_LOG"
  export PATH="${STUB_BIN}:${PATH}"
}

# stub <name> [exit-code] [stdout]
# Records "<name> <args...>" to $STUB_LOG and prints the canned stdout.
stub() {
  local name="$1" code="${2:-0}" out="${3:-}"
  cat >"${STUB_BIN}/${name}" <<STUBEOF
#!/usr/bin/env bash
printf '%s %s\n' "${name}" "\$*" >>"${STUB_LOG}"
printf '%s' '${out}'
exit ${code}
STUBEOF
  chmod +x "${STUB_BIN}/${name}"
}

# A stub whose behaviour depends on its arguments. The body is a bash case statement.
stub_script() {
  local name="$1"
  cat >"${STUB_BIN}/${name}"
  chmod +x "${STUB_BIN}/${name}"
}

# `refute <command>` — a negated assertion that can actually fail.
#
# `! cmd` is exempt from errexit: bash does not exit when the failing command's status is
# being inverted. So a `! grep -q secret "$file"` line anywhere but the LAST line of a test
# body reads like an assertion, observes nothing, and passes whatever the file holds. Every
# one of those is a test that cannot fail for the reason it is named after.
#
# Here the inversion happens inside the function, so the call site is a plain command with a
# non-zero status and errexit acts on it. `[[ a == b ]]` negations do not need this: write
# them as `[[ a != b ]]`, which is a plain command too.
refute() { ! "$@"; }

# The value of a step output, or empty.
output_value() {
  local key="$1"
  grep -E "^${key}=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-
}

calls() { cat "$STUB_LOG"; }
