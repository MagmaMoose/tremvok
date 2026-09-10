#!/usr/bin/env bats
#
# The failure these guard: this input carries a token, and every message this script can print
# lands in a run log and an ::error:: annotation that are as public as the repository. A guard
# that refuses a bad line by quoting it is worse than no guard at all. The other half is scope
# — a rewrite written to ~/.gitconfig outlives the job on a self-hosted runner and hands the
# token to whatever runs there next.

load helper

# Long enough to be a plausible token and to be masked; no `%` in it, so the mask that is
# registered is the literal string and a test can look for it.
TOKEN='ghs_A1b2C3d4E5f6G7h8I9j0' # gitleaks:allow — fabricated test value, not a real credential

setup() {
  setup_common
  cd "$WORK"
  # A developer machine may already carry rewrites of its own in exactly these variables —
  # that is what they are for — and inheriting one would shift every index these tests assert
  # on. The extend-don't-overwrite behaviour gets its own test, which sets the count itself.
  unset GIT_CONFIG_COUNT
  # If the script ever reaches for git, that is the bug: `git config --global` is the thing
  # this file exists to keep out. The stub records the attempt instead of making it.
  stub git
}

# Everything printed that is NOT an ::add-mask:: workflow command. The mask line carries the
# token by construction — that is how a token is registered — and the runner consumes it
# rather than rendering it. Every other line is log a human reads.
rendered_log() {
  printf '%s\n' "$output" | grep -v '^::add-mask::' || true
}

@test "a token never reaches the log or the step summary, because an ::error:: annotation is as public as the repository" {
  BUILD_GIT_CREDENTIALS="git.example.invalid x-access-token:${TOKEN}" \
    run bash "${SCRIPTS}/build-git-credentials.sh"
  [ "$status" -eq 0 ]
  [[ "$(rendered_log)" != *"$TOKEN"* ]]
  refute grep -qF "$TOKEN" "$GITHUB_STEP_SUMMARY"
  # The one place it is supposed to be: the environment the build's git reads.
  grep -qF "$TOKEN" "$GITHUB_ENV"
}

@test "every token is registered with ::add-mask:: on receipt, because an unmasked token printed by a later step is public for ever" {
  BUILD_GIT_CREDENTIALS="git.example.invalid x-access-token:${TOKEN}" \
    run bash "${SCRIPTS}/build-git-credentials.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::add-mask::${TOKEN}"* ]]
}

@test "a token on a line that is then refused is masked before the refusal, so the failure path cannot leak what the success path protects" {
  # Two fields after the host: refused, but the credential was already masked.
  BUILD_GIT_CREDENTIALS="git.example.invalid x-access-token:${TOKEN} extra" \
    run bash "${SCRIPTS}/build-git-credentials.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::add-mask::${TOKEN}"* ]]
  [[ "$(rendered_log)" != *"$TOKEN"* ]]
}

@test "the rewrite goes to GITHUB_ENV and git is never run, because git config --global outlives the job on a shared self-hosted runner" {
  BUILD_GIT_CREDENTIALS="git.example.invalid x-access-token:${TOKEN}" \
    run bash "${SCRIPTS}/build-git-credentials.sh"
  [ "$status" -eq 0 ]
  refute grep -q '^git ' "$STUB_LOG"
  grep -qF "GIT_CONFIG_KEY_0=url.https://x-access-token:${TOKEN}@git.example.invalid/.insteadOf" "$GITHUB_ENV"
  grep -qF 'GIT_CONFIG_VALUE_0=https://git.example.invalid/' "$GITHUB_ENV"
  grep -qF 'GIT_CONFIG_COUNT=1' "$GITHUB_ENV"
}

@test "an existing GIT_CONFIG_COUNT is extended, not overwritten, so a rewrite an earlier step set does not silently vanish" {
  GIT_CONFIG_COUNT=1 BUILD_GIT_CREDENTIALS="git.example.invalid x-access-token:${TOKEN}" \
    run bash "${SCRIPTS}/build-git-credentials.sh"
  [ "$status" -eq 0 ]
  grep -qF "GIT_CONFIG_KEY_1=url.https://x-access-token:${TOKEN}@git.example.invalid/.insteadOf" "$GITHUB_ENV"
  grep -qF 'GIT_CONFIG_COUNT=2' "$GITHUB_ENV"
  refute grep -q '^GIT_CONFIG_KEY_0=' "$GITHUB_ENV"
}

@test "GIT_CONFIG_COUNT is written last, so a line refused halfway through leaves the job's existing git configuration intact" {
  BUILD_GIT_CREDENTIALS="git.example.invalid x-access-token:${TOKEN}
bad.example.invalid nocolonhere" \
    run bash "${SCRIPTS}/build-git-credentials.sh"
  [ "$status" -ne 0 ]
  # The first line's pair is on disk, but git reads indices 0..COUNT-1 and COUNT was never
  # written, so nothing above the old count is ever read.
  refute grep -q '^GIT_CONFIG_COUNT=' "$GITHUB_ENV"
}

@test "an empty input changes nothing, so an existing caller who never sets it is unaffected" {
  run bash "${SCRIPTS}/build-git-credentials.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$GITHUB_ENV" ]
  [[ "$output" == *"untouched"* ]]
}

@test "blank lines and # comments are ignored, and an input holding only those configures nothing" {
  BUILD_GIT_CREDENTIALS='
# the docs theme lives here

' run bash "${SCRIPTS}/build-git-credentials.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$GITHUB_ENV" ]
}

@test "a line with no ':' is refused by index and host and never by content, because what is there may be the token" {
  BUILD_GIT_CREDENTIALS="# a comment

git.example.invalid ${TOKEN}" run bash "${SCRIPTS}/build-git-credentials.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"line 3"* ]]
  [[ "$output" == *"'git.example.invalid'"* ]]
  [[ "$(rendered_log)" != *"$TOKEN"* ]]
}

@test "a bare token pasted as a whole line is named by line number only, because its first field is not a host and printing it would publish it" {
  BUILD_GIT_CREDENTIALS="$TOKEN" run bash "${SCRIPTS}/build-git-credentials.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"line 1"* ]]
  [[ "$output" == *"named by index alone"* ]]
  [[ "$output" != *"$TOKEN"* ]]
}

@test "a first field carrying a ':' is never quoted, because host:port and username:token are the same shape" {
  # Only host characters in it apart from the colon, so it gets as far as host_label and the
  # colon is the one thing standing between this message and a printed credential.
  BUILD_GIT_CREDENTIALS='oauth2:0123456789abcdef' run bash "${SCRIPTS}/build-git-credentials.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *'named by line number only'* ]]
  [[ "$(rendered_log)" != *'0123456789abcdef'* ]]
}

@test "a token under 8 characters is refused, because ::add-mask:: on a short string turns every later log line into asterisks" {
  BUILD_GIT_CREDENTIALS='git.example.invalid x-access-token:abc' \
    run bash "${SCRIPTS}/build-git-credentials.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"under 8 characters"* ]]
  [[ "$output" == *"'git.example.invalid'"* ]]
  refute grep -q '^GIT_CONFIG_COUNT=' "$GITHUB_ENV"
}

@test "a token containing ':' survives, because the split is at the FIRST colon and the username is the half that cannot hold one" {
  BUILD_GIT_CREDENTIALS='git.example.invalid oauth2:aaaa:bbbb:cccc' \
    run bash "${SCRIPTS}/build-git-credentials.sh"
  [ "$status" -eq 0 ]
  grep -qF 'GIT_CONFIG_KEY_0=url.https://oauth2:aaaa:bbbb:cccc@git.example.invalid/.insteadOf' "$GITHUB_ENV"
}

@test "the same host twice is refused, because which of two rewrites git picks is not defined" {
  BUILD_GIT_CREDENTIALS="git.example.invalid x-access-token:${TOKEN}
git.example.invalid oauth2:${TOKEN}" run bash "${SCRIPTS}/build-git-credentials.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"twice"* ]]
  [[ "$output" == *"line 2"* ]]
}

@test "a URL in the host field is refused by index alone, because a credentialled URL in the wrong input must not be echoed back" {
  BUILD_GIT_CREDENTIALS="https://x-access-token:${TOKEN}@git.example.invalid/ x-access-token:${TOKEN}" \
    run bash "${SCRIPTS}/build-git-credentials.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"starts with a URL, not a host"* ]]
  [[ "$(rendered_log)" != *"$TOKEN"* ]]
}

@test "several hosts each get their own indexed pair, so a build fetching from two forges works in one run" {
  BUILD_GIT_CREDENTIALS="git.example.invalid x-access-token:${TOKEN}
scm.example.invalid oauth2:${TOKEN}2" run bash "${SCRIPTS}/build-git-credentials.sh"
  [ "$status" -eq 0 ]
  grep -qF 'GIT_CONFIG_VALUE_0=https://git.example.invalid/' "$GITHUB_ENV"
  grep -qF 'GIT_CONFIG_VALUE_1=https://scm.example.invalid/' "$GITHUB_ENV"
  grep -qF 'GIT_CONFIG_COUNT=2' "$GITHUB_ENV"
  [[ "$output" == *"'git.example.invalid', 'scm.example.invalid'"* ]]
}

@test "a non-numeric GIT_CONFIG_COUNT fails rather than being written over, because the entries it counts would go unread" {
  GIT_CONFIG_COUNT=one BUILD_GIT_CREDENTIALS="git.example.invalid x-access-token:${TOKEN}" \
    run bash "${SCRIPTS}/build-git-credentials.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GIT_CONFIG_COUNT"* ]]
}

@test "no GITHUB_ENV fails loudly, because the fetch is a later step and a silent no-op surfaces as git's own opaque auth failure" {
  GITHUB_ENV='' BUILD_GIT_CREDENTIALS="git.example.invalid x-access-token:${TOKEN}" \
    run bash "${SCRIPTS}/build-git-credentials.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GITHUB_ENV is not set"* ]]
}
