#!/usr/bin/env bats
#
# One answer to "did this run work?", shared by the notification sinks and the deployment
# record. A skip is its own status: reporting it as a failure is what makes people re-run a
# fork pull request three times before reading the reason.

load helper

setup() {
  setup_common
  cd "$WORK"
}

@test "a skip is a skip, not a failure" {
  SKIP=true run bash "${SCRIPTS}/collect-outcome.sh"
  [ "$(output_value status)" = "skipped" ]
}

@test "any target reporting a deploy sets deployed" {
  S3_DEPLOYED=true run bash "${SCRIPTS}/collect-outcome.sh"
  [ "$(output_value deployed)" = "true" ]
  : >"$GITHUB_OUTPUT"
  ANSIBLE_DEPLOYED=true run bash "${SCRIPTS}/collect-outcome.sh"
  [ "$(output_value deployed)" = "true" ]
  : >"$GITHUB_OUTPUT"
  DOCS_SITE_DIR=/tmp/site run bash "${SCRIPTS}/collect-outcome.sh"
  [ "$(output_value deployed)" = "true" ]
}

@test "a terragrunt run that only planned is a success, not a failure" {
  # It deployed nothing on purpose: it is waiting for an approval. Reporting that to Slack
  # as a failed deploy trains people to ignore the channel.
  TG_DEPLOYED=false JOB_STATUS=success run bash "${SCRIPTS}/collect-outcome.sh"
  [ "$(output_value status)" = "success" ]
  [ "$(output_value deployed)" = "false" ]
}

@test "a failed job is a failure whatever the target reported" {
  S3_DEPLOYED=true JOB_STATUS=failure run bash "${SCRIPTS}/collect-outcome.sh"
  [ "$(output_value status)" = "failure" ]
}
