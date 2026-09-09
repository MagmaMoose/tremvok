#!/usr/bin/env bats
#
# Detection rather than declaration: uv.lock in the tree is the fact, and a caller restating
# it in config is one more thing that can disagree with the repo. Everything here fails
# BEFORE the build, so a missing credential costs a second rather than two minutes.
#
# The other half is `stage-pages`. GitHub Pages has one site and no preview destination, so
# staging an artifact IS publishing. Every assertion below therefore pins both halves of that
# rule: a suite that only proved the `true` case would stay green while staging became
# unconditional, and the failure would be a pull request going live.

load helper

setup() {
  setup_common
  cd "$WORK"
  printf 'site_name: x\n' >mkdocs.yml
}

@test "a uv.lock picks uv" {
  : >uv.lock
  run bash "${SCRIPTS}/pages-detect.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value toolchain)" = "uv" ]
}

@test "no uv.lock but a requirements file picks pip" {
  mkdir -p docs && : >docs/requirements.txt
  run bash "${SCRIPTS}/pages-detect.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value toolchain)" = "pip" ]
}

@test "a requirements file somewhere else is still found when it is named" {
  mkdir -p build && : >build/reqs.txt
  REQUIREMENTS=build/reqs.txt run bash "${SCRIPTS}/pages-detect.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value toolchain)" = "pip" ]
}

@test "neither is an error, not a guess" {
  run bash "${SCRIPTS}/pages-detect.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot tell how to install MkDocs"* ]]
  [[ "$output" == *"pages-toolchain"* ]]
}

@test "an explicit toolchain overrides detection" {
  : >uv.lock
  REQUESTED=pip run bash "${SCRIPTS}/pages-detect.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value toolchain)" = "pip" ]
}

@test "an explicit uv needs no lock file to justify itself" {
  mkdir -p docs && : >docs/requirements.txt
  REQUESTED=uv run bash "${SCRIPTS}/pages-detect.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value toolchain)" = "uv" ]
}

@test "an unknown toolchain is refused and names the input" {
  : >uv.lock
  REQUESTED=poetry run bash "${SCRIPTS}/pages-detect.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pages-toolchain"* ]]
  [[ "$output" == *"poetry"* ]]
}

@test "no mkdocs.yml is refused before anything is installed" {
  rm mkdocs.yml
  : >uv.lock
  run bash "${SCRIPTS}/pages-detect.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to build"* ]]
}

# ── staging: the only thing standing between a pull request and the live site ──────────

@test "staging is what separates a deploy from a preview" {
  : >uv.lock
  run bash "${SCRIPTS}/pages-detect.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value stage-pages)" = "true" ]

  : >"$GITHUB_OUTPUT"
  MODE=preview run bash "${SCRIPTS}/pages-detect.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value stage-pages)" = "false" ]
}

@test "a preview still builds — it is a build without a destination, not a skip" {
  : >uv.lock
  MODE=preview run bash "${SCRIPTS}/pages-detect.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value toolchain)" = "uv" ]
  [ "$(output_value stage-pages)" = "false" ]
}

@test "a dry run builds and stages nothing" {
  : >uv.lock
  DRY_RUN=true MODE=deploy run bash "${SCRIPTS}/pages-detect.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value toolchain)" = "uv" ]
  [ "$(output_value stage-pages)" = "false" ]
}

@test "a dry run spelled the way Actions spells it still stages nothing" {
  # `is_true`, not a string compare: "TRUE" reading as false publishes a dry run.
  : >uv.lock
  DRY_RUN=TRUE MODE=deploy run bash "${SCRIPTS}/pages-detect.sh"
  [ "$(output_value stage-pages)" = "false" ]

  : >"$GITHUB_OUTPUT"
  DRY_RUN=yes MODE=deploy run bash "${SCRIPTS}/pages-detect.sh"
  [ "$(output_value stage-pages)" = "false" ]
}

@test "an explicit deploy with dry-run off is the one case that stages" {
  : >uv.lock
  DRY_RUN=false MODE=deploy run bash "${SCRIPTS}/pages-detect.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value stage-pages)" = "true" ]
}

# ── node ──────────────────────────────────────────────────────────────────────────────

@test "has-node is true when npx is on PATH" {
  : >uv.lock
  stub npx 0 ""
  run bash "${SCRIPTS}/pages-detect.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value has-node)" = "true" ]
}

@test "has-node is false when npx is absent, rather than exit 127 later" {
  # markdownlint died with 127 on a self-hosted runner because nobody asked first.
  : >uv.lock
  export PATH="${STUB_BIN}:/usr/bin:/bin"
  run bash "${SCRIPTS}/pages-detect.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value has-node)" = "false" ]
}
