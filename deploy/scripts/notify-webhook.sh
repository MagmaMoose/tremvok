#!/usr/bin/env bash
# Post one deployment card to Slack and/or Microsoft Teams.
#
# Both sinks are an unauthenticated incoming-webhook URL and a JSON body, so they share a
# script rather than duplicating the payload assembly twice. Each is optional and each is
# **failure-isolated**: a Slack outage cannot fail a deploy that already succeeded.
#
# The payloads are built with `jq -n --arg`, never string interpolation. A version string or a
# branch name containing a quote would otherwise produce a 400 that the failure isolation
# reports as an unexplained "notification failed".
set -euo pipefail
# shellcheck source=deploy/scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
TEAMS_WEBHOOK="${TEAMS_WEBHOOK:-}"
REPOSITORY="${REPOSITORY:-${GITHUB_REPOSITORY:-}}"
ENVIRONMENT="${ENVIRONMENT:-}"
STATUS="${STATUS:-success}"
MODE="${MODE:-deploy}"
TARGET="${TARGET:-}"
VERSION="${VERSION:-}"
URL="${URL:-}"
COMMIT="${COMMIT:-${GITHUB_SHA:-}}"
RUN_URL="${RUN_URL:-}"
ACTOR="${ACTOR:-${GITHUB_ACTOR:-}}"
VERIFIED="${VERIFIED:-false}"
NOTIFY="${NOTIFY:-always}"

case "$NOTIFY" in
  on-success) [[ "$STATUS" == "success" ]] || { tremvok::log "notify=on-success and status=${STATUS}; nothing sent"; exit 0; } ;;
  on-failure) [[ "$STATUS" == "failure" || "$STATUS" == "rolled-back" ]] || { tremvok::log "notify=on-failure and status=${STATUS}; nothing sent"; exit 0; } ;;
  always|*) ;;
esac

if [[ -z "$SLACK_WEBHOOK" && -z "$TEAMS_WEBHOOK" ]]; then
  tremvok::log "no webhook sinks configured"
  exit 0
fi

case "$STATUS" in
  success) emoji="✅" ;;
  failure) emoji="❌" ;;
  skipped) emoji="⏭️" ;;
  rolled-back) emoji="⏪" ;;
  *) emoji="•" ;;
esac

short_commit="${COMMIT:0:12}"

post() { # url  payload  label
  local url="$1" payload="$2" label="$3" code
  # --fail-with-body rather than --fail: the body of a webhook rejection is the only place the
  # reason appears, and a bare exit code sends you to the wrong wall.
  if code="$(curl --silent --show-error --fail-with-body --max-time 10 \
      --header 'content-type: application/json' --data "$payload" \
      --write-out '%{http_code}' --output /dev/null "$url" 2>&1)"; then
    tremvok::log "${label} notified (${code})"
    return 0
  fi
  tremvok::warn "${label} notification failed; the deployment is unaffected."
  return 0
}

if [[ -n "$SLACK_WEBHOOK" ]]; then
  slack_payload="$(jq -n \
    --arg text "${REPOSITORY} → ${ENVIRONMENT}: ${STATUS}" \
    --arg headline "${emoji} *${REPOSITORY}* → *${ENVIRONMENT}* — ${STATUS}" \
    --arg target "$TARGET" --arg mode "$MODE" --arg version "${VERSION:-—}" \
    --arg commit "${short_commit:-—}" --arg actor "${ACTOR:-—}" \
    --arg verified "$VERIFIED" --arg url "$URL" --arg run_url "$RUN_URL" '
    {
      text: $text,
      blocks: (
        [
          {type: "section", text: {type: "mrkdwn", text: $headline}},
          {type: "section", fields: [
            {type: "mrkdwn", text: ("*Target*\n" + $target)},
            {type: "mrkdwn", text: ("*Mode*\n" + $mode)},
            {type: "mrkdwn", text: ("*Version*\n" + $version)},
            {type: "mrkdwn", text: ("*Commit*\n" + $commit)},
            {type: "mrkdwn", text: ("*Actor*\n" + $actor)},
            {type: "mrkdwn", text: ("*Verified*\n" + $verified)}
          ]}
        ]
        + (if ($url + $run_url) == "" then [] else
            [{type: "context", elements: [{type: "mrkdwn", text: (
              [ (if $url == "" then empty else "<" + $url + "|Open the deployment>" end),
                (if $run_url == "" then empty else "<" + $run_url + "|Workflow run>" end)
              ] | join(" · ")
            )}]}]
          end)
      )
    }')"
  post "$SLACK_WEBHOOK" "$slack_payload" "Slack"
fi

if [[ -n "$TEAMS_WEBHOOK" ]]; then
  # Adaptive Cards schema URI is intentionally http:// — the MS spec requires this exact string
  _teams_schema="http://adaptivecards.io/schemas/adaptive-card.json"  # DevSkim: ignore DS137138
  teams_payload="$(jq -n \
    --arg schema "$_teams_schema" \
    --arg title "${emoji} ${REPOSITORY} → ${ENVIRONMENT}" \
    --arg status "$STATUS" --arg target "$TARGET" --arg mode "$MODE" \
    --arg version "${VERSION:-—}" --arg commit "${short_commit:-—}" \
    --arg actor "${ACTOR:-—}" --arg verified "$VERIFIED" \
    --arg url "$URL" --arg run_url "$RUN_URL" '
    {
      type: "message",
      attachments: [{
        contentType: "application/vnd.microsoft.card.adaptive",
        content: {
          "$schema": $schema,
          type: "AdaptiveCard",
          version: "1.4",
          body: [
            {type: "TextBlock", text: $title, style: "heading", wrap: true},
            {type: "FactSet", facts: [
              {title: "Status", value: $status},
              {title: "Target", value: $target},
              {title: "Mode", value: $mode},
              {title: "Version", value: $version},
              {title: "Commit", value: $commit},
              {title: "Actor", value: $actor},
              {title: "Verified", value: $verified}
            ]}
          ],
          actions: (
            [ (if $url == "" then empty else {type: "Action.OpenUrl", title: "Open deployment", url: $url} end),
              (if $run_url == "" then empty else {type: "Action.OpenUrl", title: "Workflow run", url: $run_url} end)
            ]
          )
        }
      }]
    }')"
  post "$TEAMS_WEBHOOK" "$teams_payload" "Teams"
fi
