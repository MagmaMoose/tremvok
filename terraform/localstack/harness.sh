#!/usr/bin/env bash
# The full LocalStack sequence, in one place.
#
# `make -C terraform dev` calls this, and so does CI. Two callers running two copies of the
# same six steps is how a local run and a CI run quietly stop testing the same thing — and the
# self-hosted runner images have no `make`, so CI could not have called the Makefile anyway.
#
#   up          start LocalStack and wait for it
#   down        remove it
#   api-zip     build the Lambda package with THIS repo's own script
#   apply       stand the module up inside LocalStack
#   seed        write the parameters Terraform deliberately does not create
#   smoke       drive it end to end and assert the invariants
#
# Nothing here touches a real AWS account.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-west-1}"
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}"  # DevSkim: ignore DS162092

# The zip and the function must agree: `pydantic-core` is a compiled wheel, and LocalStack runs
# the Lambda container on this host's architecture.
if [[ -z "${ARCH:-}" ]]; then
  case "$(uname -m)" in
    x86_64|amd64) ARCH=x86_64 ;;
    *) ARCH=arm64 ;;
  esac
fi

# Preconditions are checked by the step that needs them, not up front: `harness.sh api-zip`
# builds a Lambda package and needs neither Terraform nor an AWS CLI, and failing it for a
# missing tofu would be a confusing way to say "you are holding it wrong".
TFBIN="${TFBIN:-$(command -v tofu 2>/dev/null || command -v terraform 2>/dev/null || true)}"

require_tofu() {
  [[ -n "$TFBIN" ]] || { echo "no tofu or terraform on PATH" >&2; exit 1; }
}

# The smoke suite runs the action's own deploy scripts, and those call `aws` directly. The
# self-hosted runner images do not ship it, so fall back to the one in this project's dev group
# — which also means `make -C terraform dev` works on a laptop that has never installed it.
require_aws() {
  command -v aws >/dev/null 2>&1 && return 0
  local venv_bin="${ROOT}/.venv/bin"
  if [[ -x "${venv_bin}/aws" ]]; then
    export PATH="${venv_bin}:${PATH}"
    return 0
  fi
  echo "no aws CLI on PATH and none in ${venv_bin} — run 'uv sync --all-groups'" >&2
  exit 1
}

# `uv run` when available so the smoke suite gets boto3 and cryptography without the caller
# having to arrange an environment; a plain interpreter otherwise.
python_runner() {
  if command -v uv >/dev/null 2>&1; then
    ( cd "$ROOT" && uv run python "$@" )
  else
    python3 "$@"
  fi
}

CONTAINER="${CONTAINER:-tremvok-localstack}"
IMAGE="${IMAGE:-localstack/localstack:4}"

# `docker run`, not `docker compose`. The org's dind sidecar ships the Docker CLI without the
# compose plugin, so `docker compose -f …` there fails with the genuinely misleading
# `unknown shorthand flag: 'f' in -f` — docker parsing `-f` as its own flag because `compose`
# is not a command it knows. One container needs no orchestrator, and this way the laptop and
# the runner run the identical command.
#
# Every setting that used to live in docker-compose.yml is here, and this is now its only
# definition:
#
#   SERVICES               named explicitly rather than left to the default, so a service this
#                          stack starts depending on fails at boot instead of at the first API
#                          call. `s3control` is here for a non-obvious reason: AWS provider v6
#                          reads a bucket's tags through the S3 Control API rather than the S3
#                          API, so every `aws_s3_bucket` apply 501s without it.
#   LAMBDA_RUNTIME_EXECUTOR=docker
#                          Lambda runs in sibling containers on the host daemon, which is why
#                          the socket is mounted. The alternative (`local`) skips the container
#                          and with it the runtime's own import path — and the import path is
#                          exactly what a cross-architecture wheel mismatch breaks, so the
#                          cheap executor would hide the bug this harness most needs to catch.
step_up() {
  command -v docker >/dev/null 2>&1 || { echo "no docker on PATH" >&2; exit 1; }

  # Idempotent: a previous run that died before its teardown must not block this one.
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

  docker run -d --name "$CONTAINER" \
    -p 4566:4566 \
    -e "SERVICES=lambda,s3,s3control,dynamodb,ssm,kms,iam,sts,logs,cloudwatch,sns,apigateway" \
    -e "DEBUG=0" \
    -e "LAMBDA_RUNTIME_EXECUTOR=docker" \
    -e "LAMBDA_REMOVE_CONTAINERS=1" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    "$IMAGE" >/dev/null

  echo "waiting for localstack..."
  for _ in $(seq 1 90); do
    if curl -sf "${AWS_ENDPOINT_URL}/_localstack/health" >/dev/null; then
      echo "localstack is healthy"
      return 0
    fi
    # A container that has already exited will never become healthy; say so now rather than
    # after three minutes of polling something that is gone.
    if ! docker ps -q --filter "name=^${CONTAINER}$" | grep -q .; then
      echo "the localstack container exited during startup" >&2
      docker logs "$CONTAINER" 2>&1 | tail -50 >&2 || true
      return 1
    fi
    sleep 2
  done
  echo "localstack did not become healthy" >&2
  docker logs "$CONTAINER" 2>&1 | tail -50 >&2 || true
  return 1
}

step_down() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  echo "removed ${CONTAINER}"
}

step_api_zip() {
  ( cd "$ROOT" && python3 deploy/scripts/build_api_zip.py --arch "$ARCH" )
}

step_apply() {
  require_tofu
  ( cd "$HERE" \
    && "$TFBIN" init -input=false \
    && "$TFBIN" apply -auto-approve -input=false \
         -var "api_zip_path=${ROOT}/dist/tremvok-api.zip" \
         -var "architecture=${ARCH}" )
}

step_smoke() {
  require_tofu
  require_aws
  ( cd "$HERE" && "$TFBIN" output -json > "${HERE}/.outputs.json" )
  python_runner "${HERE}/smoke.py" "${HERE}/.outputs.json"
}

case "${1:-all}" in
  up) step_up ;;
  down) step_down ;;
  api-zip) step_api_zip ;;
  apply) step_apply ;;
  seed) require_aws; "${HERE}/seed.sh" ;;
  smoke) step_smoke ;;
  all)
    require_tofu
    require_aws
    step_up
    step_api_zip
    step_apply
    "${HERE}/seed.sh"
    step_smoke
    ;;
  *) echo "usage: harness.sh [all|up|down|api-zip|apply|seed|smoke]" >&2; exit 2 ;;
esac
