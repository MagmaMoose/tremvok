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
