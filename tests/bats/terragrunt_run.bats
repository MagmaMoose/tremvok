#!/usr/bin/env bats
#
# The status file and the exit code say different things on purpose. A caller that reads only
# the exit code cannot tell "nothing to do" from "something to do", and that difference is what
# decides whether a pull request needs an apply before it merges.

load helper

setup() {
  setup_common
  cd "$WORK"
  mkdir -p stack out
  stub_script terragrunt <<'STUBEOF'
#!/usr/bin/env bash
printf 'terragrunt %s\n' "$*" >>"${STUB_LOG}"
case "$1" in
  init) printf 'Initializing...\n'; exit "${INIT_EXIT:-0}" ;;
  plan) printf 'Plan: 1 to add, 0 to change, 0 to destroy.\n'; exit "${PLAN_EXIT:-2}" ;;
  apply) printf 'Apply complete.\n'; exit "${APPLY_EXIT:-0}" ;;
esac
exit 0
STUBEOF
}

@test "detailed-exitcode 0 means no changes, and that is a success" {
  PLAN_EXIT=0 run bash "${SCRIPTS}/terragrunt-run.sh" plan stack out
  [ "$status" -eq 0 ]
  [ "$(cat out/status)" = "no-changes" ]
}

@test "detailed-exitcode 2 means changes, which is also a success" {
  PLAN_EXIT=2 run bash "${SCRIPTS}/terragrunt-run.sh" plan stack out
  [ "$status" -eq 0 ]
  [ "$(cat out/status)" = "changes" ]
}

@test "any other exit code is a failure" {
  PLAN_EXIT=1 run bash "${SCRIPTS}/terragrunt-run.sh" plan stack out
  [ "$status" -ne 0 ]
  [ "$(cat out/status)" = "failed" ]
}

@test "a failed init never reaches plan" {
  INIT_EXIT=1 run bash "${SCRIPTS}/terragrunt-run.sh" plan stack out
  [ "$status" -ne 0 ]
  [ "$(cat out/status)" = "failed" ]
  ! grep -q 'terragrunt plan' "$STUB_LOG"
}

@test "the plan uses -detailed-exitcode, or none of the above can be told apart" {
  run bash "${SCRIPTS}/terragrunt-run.sh" plan stack out
  grep -q -- '-detailed-exitcode' "$STUB_LOG"
}

@test "output is buffered to a file, not streamed" {
  # Without this a failed apply leaves an empty log group and the reason nowhere at all, and
  # the output could never be redacted before reaching a pull-request comment.
  run bash "${SCRIPTS}/terragrunt-run.sh" plan stack out
  grep -q 'Plan: 1 to add' out/plan.txt
}

@test "apply runs init first and records that it applied" {
  run bash "${SCRIPTS}/terragrunt-run.sh" apply stack out
  [ "$status" -eq 0 ]
  [ "$(cat out/status)" = "applied" ]
  grep -q 'terragrunt init' "$STUB_LOG"
  grep -q -- '-auto-approve' "$STUB_LOG"
}

@test "a failed apply is recorded as failed" {
  APPLY_EXIT=1 run bash "${SCRIPTS}/terragrunt-run.sh" apply stack out
  [ "$status" -ne 0 ]
  [ "$(cat out/status)" = "failed" ]
}

@test "redact takes a file and needs no stack" {
  printf 'client_secret = "hunter2"\nfine = "value"\n' >secrets.txt
  run bash "${SCRIPTS}/terragrunt-run.sh" redact secrets.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *'client_secret = "***"'* ]]
  [[ "$output" == *'fine = "value"'* ]]
}

@test "redaction covers access keys and URL credentials too" {
  printf 'AKIAIOSFODNN7EXAMPLE\nhttps://user:pw@host/x\n' >secrets.txt
  run bash "${SCRIPTS}/terragrunt-run.sh" redact secrets.txt
  [[ "$output" != *"IOSFODNN7EXAMPLE"* ]]
  [[ "$output" != *"user:pw@"* ]]
}

@test "an unknown action fails rather than doing something surprising" {
  run bash "${SCRIPTS}/terragrunt-run.sh" destroy stack out
  [ "$status" -ne 0 ]
}
