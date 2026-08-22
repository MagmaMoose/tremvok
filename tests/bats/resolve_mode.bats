#!/usr/bin/env bats

load helper
setup() { setup_common; }

@test "a push to the default branch deploys" {
  MODE=auto EVENT_NAME=push REF=refs/heads/main DEFAULT_BRANCH=main \
    run bash "${SCRIPTS}/resolve-mode.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value mode)" = "deploy" ]
  [ "$(output_value environment)" = "production" ]
}

@test "a push to a topic branch refuses rather than guessing" {
  MODE=auto EVENT_NAME=push REF=refs/heads/feat/x DEFAULT_BRANCH=main \
    run bash "${SCRIPTS}/resolve-mode.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"only refs/heads/main deploys"* ]]
}

@test "a pull request previews under a stable pr-N alias" {
  MODE=auto EVENT_NAME=pull_request REF=refs/pull/42/merge PR_NUMBER=42 \
    run bash "${SCRIPTS}/resolve-mode.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value mode)" = "preview" ]
  [ "$(output_value preview-alias)" = "pr-42" ]
  [ "$(output_value environment)" = "preview" ]
}

@test "a manual run from a topic branch cannot publish to production" {
  # The rule this protects: "Run workflow" from a branch would otherwise deploy that branch,
  # be recorded as a deploy, and only surface when the next release reverts it.
  MODE=auto EVENT_NAME=workflow_dispatch REF=refs/heads/spike DEFAULT_BRANCH=main \
    run bash "${SCRIPTS}/resolve-mode.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must start from main"* ]]
}

@test "a manual run from a topic branch is allowed when explicitly opted in" {
  MODE=auto EVENT_NAME=workflow_dispatch REF=refs/heads/spike DEFAULT_BRANCH=main \
    ALLOW_DISPATCH_FROM_ANY_REF=true run bash "${SCRIPTS}/resolve-mode.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value mode)" = "deploy" ]
}

@test "an explicit mode overrides the event" {
  MODE=preview EVENT_NAME=push REF=refs/heads/main PR_NUMBER=7 \
    run bash "${SCRIPTS}/resolve-mode.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value mode)" = "preview" ]
}

@test "an unknown event under auto fails loudly" {
  MODE=auto EVENT_NAME=issue_comment run bash "${SCRIPTS}/resolve-mode.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot derive a mode"* ]]
}

@test "an unknown explicit mode fails" {
  MODE=yolo EVENT_NAME=push run bash "${SCRIPTS}/resolve-mode.sh"
  [ "$status" -ne 0 ]
}

@test "a preview alias is slugified so it is URL-safe" {
  MODE=preview EVENT_NAME=pull_request PREVIEW_ALIAS='Feature/Add Thing!' \
    run bash "${SCRIPTS}/resolve-mode.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value preview-alias)" = "feature-add-thing" ]
}

@test "a preview with no pull request and no alias fails rather than inventing one" {
  MODE=preview EVENT_NAME=workflow_dispatch REF=refs/heads/main run bash "${SCRIPTS}/resolve-mode.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"preview-alias"* ]]
}
