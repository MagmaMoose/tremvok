#!/usr/bin/env bats

load helper
setup() { setup_common; unset AWS_ACCESS_KEY_ID AWS_WEB_IDENTITY_TOKEN_FILE; }

@test "a fork pull request skips with a reason, not an auth error" {
  IS_FORK=true ROLE_TO_ASSUME=arn:aws:iam::1:role/x run bash "${SCRIPTS}/preflight.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value skip)" = "true" ]
  [[ "$(output_value skip-reason)" == *"fork"* ]]
  grep -q "Tremvok — skipped" "$GITHUB_STEP_SUMMARY"
}

@test "an unwired repository skips with a reason" {
  IS_FORK=false ROLE_TO_ASSUME= run bash "${SCRIPTS}/preflight.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value skip)" = "true" ]
  [[ "$(output_value skip-reason)" == *"no AWS credential"* ]]
}

@test "a role makes it proceed" {
  IS_FORK=false ROLE_TO_ASSUME=arn:aws:iam::1:role/x run bash "${SCRIPTS}/preflight.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value skip)" = "false" ]
}

@test "ambient credentials from an earlier step are accepted" {
  IS_FORK=false ROLE_TO_ASSUME= AWS_ACCESS_KEY_ID=AKIAEXAMPLE run bash "${SCRIPTS}/preflight.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value skip)" = "false" ]
}

@test "a fork preview can be opted into" {
  IS_FORK=true ALLOW_FORK_PREVIEW=true ROLE_TO_ASSUME=arn:aws:iam::1:role/x \
    run bash "${SCRIPTS}/preflight.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value skip)" = "false" ]
}
