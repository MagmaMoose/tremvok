#!/usr/bin/env bash
# Render the deploy summary a pull request gets, then hand it to the sticky-comment
# poster. Separated from notify-pr.sh so that script stays "put this text on that pull
# request" and nothing else — it is the piece three repositories had three copies of.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${here}/lib/common.sh"

MODE="${MODE:-deploy}"
TARGET="${TARGET:-}"
ENVIRONMENT="${ENVIRONMENT:-}"
STATUS="${STATUS:-}"
URL="${URL:-}"
VERSION="${VERSION:-}"
VERIFIED="${VERIFIED:-}"
RUN_URL="${RUN_URL:-}"

# `if` blocks rather than `[[ … ]] && printf` inside the substitution: a false test as the
# LAST command of a command substitution makes the assignment fail, and under `set -e` that
# ends the script. It only bites when the optional line is absent, which is the common case.
body="$(
  printf '### Tremvok — %s `%s` to `%s`\n\n' "$MODE" "$TARGET" "$ENVIRONMENT"
  printf '| | |\n|:--|:--|\n'
  printf '| Status | `%s` |\n' "$STATUS"
  if [[ -n "$URL" ]]; then printf '| URL | %s |\n' "$URL"; fi
  if [[ -n "$VERSION" ]]; then printf '| Version | `%s` |\n' "$VERSION"; fi
  printf '| Verified | `%s` |\n' "${VERIFIED:-not checked}"
  printf '| Commit | `%s` |\n' "${GITHUB_SHA:0:12}"
  printf '\n[Workflow run](%s)\n' "$RUN_URL"
)"

BODY="$body" bash "${here}/notify-pr.sh"
