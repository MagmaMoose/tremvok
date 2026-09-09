#!/usr/bin/env bats
#
# The whole answer to "a target enum is a listing that cannot say what it does" lives here.
# The objection is only fair when the inapplicable inputs are silently ignored, so these
# tests are what make sure they never are.

load helper

setup() {
  setup_common
  cd "$WORK"
}

@test "an input that belongs to another target is a hard error naming both" {
  TARGET=ansible INPUTS_JSON='{"s3-bucket":"my-bucket"}' \
    run bash "${SCRIPTS}/validate-inputs.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"do not apply to target: ansible"* ]]
  [[ "$output" == *"s3-bucket"* ]]
  [[ "$output" == *"s3-cloudfront, lambda-zip"* ]]
}

@test "every mistake is reported at once, not one per attempt" {
  TARGET=github-pages INPUTS_JSON='{"s3-bucket":"b","terragrunt-root":"infra","ansible-playbook":"site.yml"}' \
    run bash "${SCRIPTS}/validate-inputs.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"s3-bucket"* ]]
  [[ "$output" == *"terragrunt-root"* ]]
  [[ "$output" == *"ansible-playbook"* ]]
}

@test "inputs that belong to the target are accepted" {
  TARGET=terragrunt INPUTS_JSON='{"terragrunt-root":"infra","terragrunt-scope":"all","aws-region":"eu-west-1"}' \
    run bash "${SCRIPTS}/validate-inputs.sh"
  [ "$status" -eq 0 ]
}

@test "shared inputs are accepted for every target" {
  for target in github-pages s3-cloudfront lambda-zip terragrunt ansible cloudflare-workers; do
    TARGET="$target" INPUTS_JSON='{"working-directory":"sub","verify-url":"https://example.com","notify":"on-failure"}' \
      run bash "${SCRIPTS}/validate-inputs.sh"
    [ "$status" -eq 0 ]
  done
}

@test "an input left at its default is not a mistake, whatever the target" {
  # A composite action cannot tell "unset" from "set to the default", and an input holding
  # its default changes nothing — so the blind spot has to be silent rather than noisy.
  TARGET=ansible INPUTS_JSON='{"s3-delete-orphans":"auto","lambda-function-alias":"live"}' \
    run bash "${SCRIPTS}/validate-inputs.sh"
  [ "$status" -eq 0 ]
}

@test "an aws-shared input is refused for every target that never touches AWS" {
  for target in github-pages ansible cloudflare-workers; do
    TARGET="$target" INPUTS_JSON='{"aws-region":"eu-west-1"}' \
      run bash "${SCRIPTS}/validate-inputs.sh"
    [ "$status" -ne 0 ]
  done
}

@test "an unknown target is refused, and the message lists the real ones" {
  TARGET=kubernetes INPUTS_JSON='{}' run bash "${SCRIPTS}/validate-inputs.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown target 'kubernetes'"* ]]
  [[ "$output" == *"s3-cloudfront"* ]]
}

@test "no target at all is refused rather than defaulted" {
  # There is no sensible default. Guessing `github-pages` would silently build a site for somebody
  # who meant to deploy a Lambda.
  TARGET= INPUTS_JSON='{}' run bash "${SCRIPTS}/validate-inputs.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"target is required"* ]]
}

@test "the run summary names the inputs and where they belong" {
  TARGET=github-pages INPUTS_JSON='{"lambda-function-name":"fn"}' \
    run bash "${SCRIPTS}/validate-inputs.sh"
  grep -q 'inputs do not match the target' "$GITHUB_STEP_SUMMARY"
  grep -q 'lambda-function-name' "$GITHUB_STEP_SUMMARY"
}

@test "an unset INPUTS_JSON defaults to an empty object, and a set one is passed through" {
  # Regression. `INPUTS_JSON="${INPUTS_JSON:-{}}"` closes the expansion at the first `}`, so a
  # SET value silently gained a trailing `}` and jq rejected every run, while the unset case
  # still produced `{}` and looked fine. Both halves get asserted, or the next rewrite of this
  # one line reintroduces it.
  TARGET=ansible run bash "${SCRIPTS}/validate-inputs.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"inputs validated for target=ansible"* ]]

  TARGET=ansible INPUTS_JSON='{"ansible-limit":"host-a"}' run bash "${SCRIPTS}/validate-inputs.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"invalid JSON"* ]]
}

@test "a missing applicability map fails rather than waving everything through" {
  INPUT_TARGETS_MAP="${WORK}/nope.json" TARGET=github-pages INPUTS_JSON='{"s3-bucket":"b"}' \
    run bash "${SCRIPTS}/validate-inputs.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"map is missing"* ]]
}
