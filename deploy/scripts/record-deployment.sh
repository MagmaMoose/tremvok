#!/usr/bin/env bash
# Record this deployment with the Tremvok API, authenticating with a GitHub Actions OIDC token.
#
# Optional: leave `api-url` empty and the action never calls this. When it is set, the point is
# that the consumer repository holds **no credential at all** — the token is minted by GitHub
# for this run, expires in minutes, and carries a `repository` claim the workflow cannot forge.
# That is also why the request body has no repository field: the server takes it from the
# token. See `src/tremvok/oidc.py`.
#
# **Failure-isolated**, like the other sinks. A deployment history that missed an entry is a
# gap in a report; a deploy failed by its own bookkeeping is an outage.
set -euo pipefail
# shellcheck source=deploy/scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

API_URL="${API_URL:-}"
API_AUDIENCE="${API_AUDIENCE:-tremvok}"
ENVIRONMENT="${ENVIRONMENT:-}"
STATUS="${STATUS:-success}"
TARGET="${TARGET:-other}"
MODE="${MODE:-deploy}"
VERSION="${VERSION:-}"
URL="${URL:-}"
COMMIT="${COMMIT:-${GITHUB_SHA:-}}"
RUN_URL="${RUN_URL:-}"
ACTOR="${ACTOR:-${GITHUB_ACTOR:-}}"
VERIFIED="${VERIFIED:-false}"
DETAIL="${DETAIL:-}"
DELIVERY_ID="${DELIVERY_ID:-}"

if [[ -z "$API_URL" ]]; then
  tremvok::log "no api-url set; not recording this deployment"
  exit 0
fi

if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" || -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
  tremvok::warn "api-url is set but this job has no OIDC token: add 'permissions: id-token: write' to the workflow. The deployment happened; it was not recorded."
  exit 0
fi

# The idempotency key. Run id and attempt make it stable across a retried *step* and different
# across a re-run of the job, which is exactly the line between "the same deployment, reported
# twice" and "a second deployment".
if [[ -z "$DELIVERY_ID" ]]; then
  DELIVERY_ID="${GITHUB_RUN_ID:-local}:${GITHUB_RUN_ATTEMPT:-1}:${ENVIRONMENT}:${MODE}"
fi

token="$(curl --silent --show-error --max-time 15 \
  --header "authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${API_AUDIENCE}" | jq -r '.value // empty')" || token=""

if [[ -z "$token" ]]; then
  tremvok::warn "could not mint an OIDC token for audience '${API_AUDIENCE}'; the deployment was not recorded."
  exit 0
fi

# `--arg` everywhere, and null rather than "" for the optional fields: the API rejects an empty
# string where it expects a URL, and an unset field is the honest representation of "this
# target does not produce one".
payload="$(jq -n \
  --arg delivery_id "$DELIVERY_ID" \
  --arg environment "$ENVIRONMENT" \
  --arg status "$STATUS" \
  --arg target "$TARGET" \
  --arg mode "$MODE" \
  --arg version "$VERSION" \
  --arg url "$URL" \
  --arg commit "$COMMIT" \
  --arg run_url "$RUN_URL" \
  --arg actor "$ACTOR" \
  --arg detail "$DETAIL" \
  --argjson verified "$(tremvok::is_true "$VERIFIED" && echo true || echo false)" '
  {
    delivery_id: $delivery_id,
    environment: $environment,
    status: $status,
    target: $target,
    mode: $mode,
    verified: $verified
  }
  + (if $version == "" then {} else {version: $version} end)
  + (if $url == "" then {} else {url: $url} end)
  + (if $commit == "" then {} else {commit: $commit} end)
  + (if $run_url == "" then {} else {run_url: $run_url} end)
  + (if $actor == "" then {} else {actor: $actor} end)
  + (if $detail == "" then {} else {detail: $detail} end)
  ')"

response="$(curl --silent --show-error --max-time 20 \
  --header "authorization: Bearer ${token}" \
  --header 'content-type: application/json' \
  --data "$payload" \
  --write-out '\n%{http_code}' \
  "${API_URL%/}/v1/deployments" 2>&1)" || response=$'\n000'

code="$(tail -n1 <<<"$response")"
body="$(sed '$d' <<<"$response")"

if [[ "$code" == "200" || "$code" == "201" ]]; then
  deployment_id="$(jq -r '.deployment_id // empty' <<<"$body" 2>/dev/null || true)"
  duplicate="$(jq -r '.duplicate // false' <<<"$body" 2>/dev/null || echo false)"
  tremvok::log "recorded deployment ${deployment_id:-<duplicate>} (duplicate=${duplicate})"
  tremvok::set_output record-id "$deployment_id"
else
  # Deliberately not printing the body verbatim at error level — it is a server response and a
  # 403 here is a configuration problem, not something the deploying repository can fix.
  tremvok::warn "the Tremvok API returned ${code}; the deployment was not recorded. The deploy itself succeeded."
  tremvok::set_output record-id ""
fi
