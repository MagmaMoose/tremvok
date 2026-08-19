#!/usr/bin/env bats

load helper

setup() {
  setup_common
  export GITHUB_REPOSITORY=MagmaMoose/infra
  export GITHUB_API_URL=https://api.github.com
  export AUTH_TOKEN=ghs_test
  export PR_NUMBER=42
}

# reviews <json> — an `api` stub answering the PR call with an author and the reviews call
# with the given array.
reviews() {
  REVIEWS="$1" stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
case "$*" in
  *"/reviews?"*)
    case "$*" in
      *"page=1"*) printf '%s' "$REVIEWS" ;;
      *) printf '[]' ;;
    esac ;;
  *) printf '%s' '{"user":{"login":"author"}}' ;;
esac
STUBEOF
  export REVIEWS="$1"
}

@test "an approval counts" {
  reviews '[{"user":{"login":"reviewer"},"state":"APPROVED","submitted_at":"2026-08-18T10:00:00Z"}]'
  run bash "${SCRIPTS}/approval-gate.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "reviewer" ]
}

@test "a self-approval does not" {
  reviews '[{"user":{"login":"author"},"state":"APPROVED","submitted_at":"2026-08-18T10:00:00Z"}]'
  run bash "${SCRIPTS}/approval-gate.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a later CHANGES_REQUESTED revokes an earlier approval" {
  # Too lenient here and a dismissed approval still authorises an apply.
  reviews '[{"user":{"login":"reviewer"},"state":"APPROVED","submitted_at":"2026-08-18T10:00:00Z"},{"user":{"login":"reviewer"},"state":"CHANGES_REQUESTED","submitted_at":"2026-08-18T11:00:00Z"}]'
  run bash "${SCRIPTS}/approval-gate.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a dismissal revokes an approval" {
  reviews '[{"user":{"login":"reviewer"},"state":"APPROVED","submitted_at":"2026-08-18T10:00:00Z"},{"user":{"login":"reviewer"},"state":"DISMISSED","submitted_at":"2026-08-18T11:00:00Z"}]'
  run bash "${SCRIPTS}/approval-gate.sh"
  [ -z "$output" ]
}

@test "a re-approval after changes requested counts again" {
  reviews '[{"user":{"login":"reviewer"},"state":"CHANGES_REQUESTED","submitted_at":"2026-08-18T10:00:00Z"},{"user":{"login":"reviewer"},"state":"APPROVED","submitted_at":"2026-08-18T12:00:00Z"}]'
  run bash "${SCRIPTS}/approval-gate.sh"
  [ "$output" = "reviewer" ]
}

@test "a COMMENTED review is not decisive either way" {
  reviews '[{"user":{"login":"reviewer"},"state":"APPROVED","submitted_at":"2026-08-18T10:00:00Z"},{"user":{"login":"reviewer"},"state":"COMMENTED","submitted_at":"2026-08-18T11:00:00Z"}]'
  run bash "${SCRIPTS}/approval-gate.sh"
  [ "$output" = "reviewer" ]
}

@test "two reviewers are both reported, once each" {
  reviews '[{"user":{"login":"a"},"state":"APPROVED","submitted_at":"2026-08-18T10:00:00Z"},{"user":{"login":"b"},"state":"APPROVED","submitted_at":"2026-08-18T10:30:00Z"},{"user":{"login":"a"},"state":"APPROVED","submitted_at":"2026-08-18T11:00:00Z"}]'
  run bash "${SCRIPTS}/approval-gate.sh"
  [ "$(printf '%s' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [[ "$output" == *"a"* && "$output" == *"b"* ]]
}

@test "an unreadable review list fails rather than reading as 'nobody approved'" {
  # The difference that matters: no approvers means "wait"; an API error must never be
  # allowed to mean the same thing to a caller deciding whether to apply.
  stub curl 22 ''
  run bash "${SCRIPTS}/approval-gate.sh"
  [ "$status" -ne 0 ]
}
