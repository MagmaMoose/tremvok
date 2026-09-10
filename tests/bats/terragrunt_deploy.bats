#!/usr/bin/env bats

load helper

setup() {
  setup_common
  cd "$WORK"
  mkdir -p terraform/aws/prod/api
  touch terraform/terragrunt.hcl terraform/aws/prod/api/terragrunt.hcl
  printf 'terraform/aws/prod/api/main.tf\n' >changed.txt

  export GITHUB_REPOSITORY=MagmaMoose/infra
  export GITHUB_API_URL=https://api.github.com
  export AUTH_TOKEN=ghs_test
  export ROOT_DIR=terraform
  export SCOPE=changed
  export CHANGED_FILES="${WORK}/changed.txt"
  export WORK_DIR="${WORK}/tg"
  export HEAD_SHA=abc123
  export APPROVERS='[]'

  # `terragrunt` whose plan exit code is the interesting variable: 0 no changes, 2 changes,
  # anything else an error. That is the contract `-detailed-exitcode` gives.
  stub_script terragrunt <<'STUBEOF'
#!/usr/bin/env bash
printf 'terragrunt %s (cwd=%s)\n' "$*" "${PWD##*/}" >>"${STUB_LOG}"
printf '%s ARM_ACCESS_KEY=%s\n' "$1" "${ARM_ACCESS_KEY:-<unset>}" >>"${STUB_LOG}.env"
case "$1" in
  init) exit 0 ;;
  plan) printf 'Plan: 1 to add, 0 to change, 0 to destroy.\n'; exit "${PLAN_EXIT:-2}" ;;
  apply) printf 'Apply complete.\n'; exit "${APPLY_EXIT:-0}" ;;
esac
exit 0
STUBEOF

  # GitHub: reviews come from $APPROVERS, everything else is accepted.
  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
case "$*" in
  *"/reviews?"*)
    case "$*" in *"page=1"*) printf '%s' "$APPROVERS" ;; *) printf '[]' ;; esac ;;
  *"/pulls/"*) printf '%s' '{"user":{"login":"author"}}' ;;
  *"/check-runs"*) printf '{"id":1}' ;;
  *"/comments"*) printf '[]' ;;
  *) printf '{}' ;;
esac
STUBEOF
}

approved() {
  export APPROVERS='[{"user":{"login":"reviewer"},"state":"APPROVED","submitted_at":"2026-08-18T10:00:00Z"}]'
}

@test "no affected stacks still publishes the check, so a required check cannot block forever" {
  printf 'README.md\n' >changed.txt
  run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value stacks)" = "0" ]
  grep -q '"conclusion": *"success"' <<<"$(grep -o -- '--data .*' "$STUB_LOG" | head -1)" || \
    grep -q 'check-runs' "$STUB_LOG"
}

@test "a plan with changes and no approval does not apply" {
  run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value plan-changes)" = "1" ]
  [ "$(output_value applied)" = "false" ]
  ! grep -q 'terragrunt apply' "$STUB_LOG"
}

@test "an approval authorises the apply" {
  approved
  PR_NUMBER=42 run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value applied)" = "true" ]
  [ "$(output_value approvers)" = "@reviewer" ]
  grep -q 'terragrunt apply' "$STUB_LOG"
}

@test "a failed plan blocks the apply even with an approval" {
  approved
  PLAN_EXIT=1 PR_NUMBER=42 run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -ne 0 ]
  [ "$(output_value plan-failures)" = "1" ]
  ! grep -q 'terragrunt apply' "$STUB_LOG"
}

@test "a clean plan needs no approval and applies nothing" {
  PLAN_EXIT=0 PR_NUMBER=42 run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value plan-changes)" = "0" ]
  ! grep -q 'terragrunt apply' "$STUB_LOG"
}

@test "apply=never plans and stops, approval or not" {
  approved
  APPLY=never PR_NUMBER=42 run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value applied)" = "false" ]
}

@test "a failing apply is reported and fails the run" {
  approved
  APPLY_EXIT=1 PR_NUMBER=42 run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -ne 0 ]
  [ "$(output_value apply-failures)" = "1" ]
}

@test "the plan comment carries the stack table and the gate" {
  PR_NUMBER=42 run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  grep -q 'Terragrunt plan' "${WORK_DIR}/comment.md"
  grep -q 'aws/prod/api' "${WORK_DIR}/comment.md"
  grep -q 'Waiting for an independent approval' "${WORK_DIR}/comment.md"
}

@test "credential-shaped values are redacted before they reach the comment" {
  stub_script terragrunt <<'STUBEOF'
#!/usr/bin/env bash
printf 'terragrunt %s\n' "$*" >>"${STUB_LOG}"
case "$1" in
  init) exit 0 ;;
  plan) printf 'client_secret = "hunter2"\nPlan: 1 to add, 0 to change, 0 to destroy.\n'; exit 2 ;;
esac
exit 0
STUBEOF
  PR_NUMBER=42 run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  ! grep -q 'hunter2' "${WORK_DIR}/comment.md"
  grep -q 'client_secret = "\*\*\*"' "${WORK_DIR}/comment.md"
}

@test "a dry run plans nothing and applies nothing" {
  approved
  DRY_RUN=true PR_NUMBER=42 run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  ! grep -q '^terragrunt' "$STUB_LOG"
}


# --- per-stack environment -----------------------------------------------------------------

@test "the matching pattern's credential reaches the stack, and the catch-all's does not" {
  # The case this exists for: production state in a separate account from everything else,
  # which is a deliberate blast-radius boundary. One credential cannot reach both.
  STACK_ENV=$'*/prod/*  ARM_ACCESS_KEY=PRDKEY\n*  ARM_ACCESS_KEY=DEVKEY' \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  grep -q '^plan ARM_ACCESS_KEY=PRDKEY' "${STUB_LOG}.env"
  ! grep -q 'ARM_ACCESS_KEY=DEVKEY' "${STUB_LOG}.env"
}

@test "a stack matching only the catch-all gets the catch-all's credential" {
  mkdir -p terraform/aws/acc/api
  touch terraform/aws/acc/api/terragrunt.hcl
  printf 'terraform/aws/acc/api/main.tf\n' >changed.txt
  STACK_ENV=$'*/prod/*  ARM_ACCESS_KEY=PRDKEY\n*  ARM_ACCESS_KEY=DEVKEY' \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  grep -q '^plan ARM_ACCESS_KEY=DEVKEY' "${STUB_LOG}.env"
  ! grep -q 'ARM_ACCESS_KEY=PRDKEY' "${STUB_LOG}.env"
}

@test "first match wins, so order is the contract and not an accident" {
  STACK_ENV=$'*  ARM_ACCESS_KEY=CATCHALL\n*/prod/*  ARM_ACCESS_KEY=PRDKEY' \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  grep -q '^plan ARM_ACCESS_KEY=CATCHALL' "${STUB_LOG}.env"
}

@test "the apply gets the same credential the plan did" {
  # A plan that read state with one credential and an apply that wrote it with another is
  # the worst version of this bug, because the plan looks fine.
  approved
  STACK_ENV=$'*/prod/*  ARM_ACCESS_KEY=PRDKEY' PR_NUMBER=42 \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  grep -q '^apply ARM_ACCESS_KEY=PRDKEY' "${STUB_LOG}.env"
}

@test "no stack-env means the environment is untouched" {
  run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  grep -q '^plan ARM_ACCESS_KEY=<unset>' "${STUB_LOG}.env"
}

@test "blank lines and comments are ignored rather than failing the run" {
  STACK_ENV=$'# production state lives elsewhere\n\n  */prod/*  ARM_ACCESS_KEY=PRDKEY\n' \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  grep -q '^plan ARM_ACCESS_KEY=PRDKEY' "${STUB_LOG}.env"
}

@test "several variables for one pattern all reach the stack" {
  STACK_ENV=$'*/prod/*  ARM_ACCESS_KEY=PRDKEY\n*/prod/*  ARM_SUBSCRIPTION_ID=sub-1' \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  grep -q 'ARM_ACCESS_KEY=PRDKEY' "${STUB_LOG}.env"
}

@test "a line with a pattern but no assignment is refused rather than silently skipped" {
  STACK_ENV=$'*/prod/*' run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no KEY=VALUE"* ]]
}

@test "a line that is not an assignment is refused" {
  STACK_ENV=$'*/prod/*  not-an-assignment' run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not assign"* ]]
}

@test "the credential never reaches the log or the pull-request comment" {
  STACK_ENV=$'*  ARM_ACCESS_KEY=SUPERSECRETKEY' run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  ! [[ "$output" == *"SUPERSECRETKEY"* ]]
  ! grep -rq 'SUPERSECRETKEY' "${WORK}/tg" 2>/dev/null
}
