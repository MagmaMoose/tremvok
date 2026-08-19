#!/usr/bin/env bash
# The full LocalStack sequence, in one place.
#
# `make -C terraform dev` calls this, and so does CI. Two callers running two copies of the
# same six steps is how a local run and a CI run quietly stop testing the same thing — and the
# self-hosted runner images have no `make`, so CI could not have called the Makefile anyway.
#
#   up          start LocalStack and wait for it
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

TFBIN="${TFBIN:-$(command -v tofu 2>/dev/null || command -v terraform 2>/dev/null || true)}"
[[ -n "$TFBIN" ]] || { echo "no tofu or terraform on PATH" >&2; exit 1; }

# `uv run` when available so the smoke suite gets boto3 and cryptography without the caller
# having to arrange an environment; a plain interpreter otherwise.
python_runner() {
  if command -v uv >/dev/null 2>&1; then
    ( cd "$ROOT" && uv run python "$@" )
  else
    python3 "$@"
  fi
}

step_up() {
  docker compose -f "${HERE}/docker-compose.yml" up -d
  echo "waiting for localstack..."
  for _ in $(seq 1 60); do
    if curl -sf "${AWS_ENDPOINT_URL}/_localstack/health" >/dev/null; then
      echo "localstack is healthy"
      return 0
    fi
    sleep 2
  done
  echo "localstack did not become healthy" >&2
  docker compose -f "${HERE}/docker-compose.yml" logs --tail 50 >&2 || true
  return 1
}

step_api_zip() {
  ( cd "$ROOT" && python3 scripts/build_api_zip.py --arch "$ARCH" )
}

step_apply() {
  ( cd "$HERE" \
    && "$TFBIN" init -input=false \
    && "$TFBIN" apply -auto-approve -input=false \
         -var "api_zip_path=${ROOT}/dist/tremvok-api.zip" \
         -var "architecture=${ARCH}" )
}

step_smoke() {
  ( cd "$HERE" && "$TFBIN" output -json > "${HERE}/.outputs.json" )
  python_runner "${HERE}/smoke.py" "${HERE}/.outputs.json"
}

case "${1:-all}" in
  up) step_up ;;
  api-zip) step_api_zip ;;
  apply) step_apply ;;
  seed) "${HERE}/seed.sh" ;;
  smoke) step_smoke ;;
  all)
    step_up
    step_api_zip
    step_apply
    "${HERE}/seed.sh"
    step_smoke
    ;;
  *) echo "usage: harness.sh [all|up|api-zip|apply|seed|smoke]" >&2; exit 2 ;;
esac
