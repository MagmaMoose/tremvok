#!/usr/bin/env bats
#
# Detection rather than declaration: uv.lock in the tree is the fact, and a caller restating
# it in config is one more thing that can disagree with the repo. Everything here fails
# BEFORE the build, so a missing credential costs a second rather than two minutes.

load helper

setup() {
  setup_common
  cd "$WORK"
  printf 'site_name: x\n' >mkdocs.yml
}

@test "a uv.lock picks uv" {
  : >uv.lock
  run bash "${SCRIPTS}/docs-detect.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value toolchain)" = "uv" ]
}

@test "no uv.lock but a requirements file picks pip" {
  mkdir -p docs && : >docs/requirements.txt
  run bash "${SCRIPTS}/docs-detect.sh"
  [ "$(output_value toolchain)" = "pip" ]
}

@test "neither is an error, not a guess" {
  run bash "${SCRIPTS}/docs-detect.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot tell how to install MkDocs"* ]]
}

@test "an explicit toolchain overrides detection" {
  : >uv.lock
  REQUESTED=pip run bash "${SCRIPTS}/docs-detect.sh"
  [ "$(output_value toolchain)" = "pip" ]
}

@test "no mkdocs.yml is refused before anything is installed" {
  rm mkdocs.yml
  : >uv.lock
  run bash "${SCRIPTS}/docs-detect.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to build"* ]]
}

@test "github-pages stages an artifact; nothing else does" {
  : >uv.lock
  run bash "${SCRIPTS}/docs-detect.sh"
  [ "$(output_value stage-pages)" = "true" ]
  : >"$GITHUB_OUTPUT"
  TARGET=none run bash "${SCRIPTS}/docs-detect.sh"
  [ "$(output_value stage-pages)" = "false" ]
}

@test "an unknown docs-target is refused" {
  : >uv.lock
  TARGET=netlify run bash "${SCRIPTS}/docs-detect.sh"
  [ "$status" -ne 0 ]
}
