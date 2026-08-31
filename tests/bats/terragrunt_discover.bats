#!/usr/bin/env bats

load helper

setup() {
  setup_common
  cd "$WORK"
  mkdir -p terraform/aws/prod/eu-west-1/api terraform/aws/prod/eu-west-1/artifacts \
           terraform/aws/modules/tremvok-api terraform/oci/prod/network
  touch terraform/terragrunt.hcl terraform/root.hcl
  touch terraform/aws/prod/eu-west-1/api/terragrunt.hcl
  touch terraform/aws/prod/eu-west-1/artifacts/terragrunt.hcl
  touch terraform/aws/modules/tremvok-api/terragrunt.hcl
  touch terraform/oci/prod/network/terragrunt.hcl
}

@test "all finds every leaf and never the shared root" {
  run bash "${SCRIPTS}/terragrunt-discover.sh" all
  [ "$status" -eq 0 ]
  [[ "$output" == *"terraform/aws/prod/eu-west-1/api"* ]]
  [[ "$output" == *"terraform/oci/prod/network"* ]]
  # `terraform/` itself holds the shared include, not a stack.
  ! grep -qx "terraform" <<<"$output"
}

@test "modules are excluded: a module has no state of its own" {
  run bash "${SCRIPTS}/terragrunt-discover.sh" all
  ! [[ "$output" == *"modules/tremvok-api"* ]]
}

@test "a changed file maps to its enclosing stack" {
  printf 'terraform/aws/prod/eu-west-1/api/terragrunt.hcl\n' >changed.txt
  run bash "${SCRIPTS}/terragrunt-discover.sh" changed changed.txt
  [ "$output" = "terraform/aws/prod/eu-west-1/api" ]
}

@test "a file nested inside a stack still finds it" {
  mkdir -p terraform/aws/prod/eu-west-1/api/files/deep
  printf 'terraform/aws/prod/eu-west-1/api/files/deep/policy.json\n' >changed.txt
  run bash "${SCRIPTS}/terragrunt-discover.sh" changed changed.txt
  [ "$output" = "terraform/aws/prod/eu-west-1/api" ]
}

@test "a changed module maps to nothing rather than to everything" {
  # Guessing which stacks use a module from its path is how a module tidy-up plans the whole
  # estate. Nothing is the honest answer; the scheduled drift run still covers it.
  printf 'terraform/aws/modules/tremvok-api/main.tf\n' >changed.txt
  run bash "${SCRIPTS}/terragrunt-discover.sh" changed changed.txt
  [ -z "$output" ]
}

@test "an unrelated changed file maps to nothing" {
  printf 'README.md\n.github/workflows/ci.yaml\n' >changed.txt
  run bash "${SCRIPTS}/terragrunt-discover.sh" changed changed.txt
  [ -z "$output" ]
}

@test "several files in one stack yield it once" {
  printf 'terraform/aws/prod/eu-west-1/api/terragrunt.hcl\nterraform/aws/prod/eu-west-1/api/x.tf\n' >changed.txt
  run bash "${SCRIPTS}/terragrunt-discover.sh" changed changed.txt
  [ "$(wc -l <<<"$output")" -eq 1 ]
}

@test "a deleted file's stack is still found" {
  printf 'terraform/oci/prod/network/gone.tf\n' >changed.txt
  run bash "${SCRIPTS}/terragrunt-discover.sh" changed changed.txt
  [ "$output" = "terraform/oci/prod/network" ]
}
