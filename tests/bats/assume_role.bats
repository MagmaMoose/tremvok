#!/usr/bin/env bats
#
# This script is the one that touches production credentials, and it had no tests. The three
# things that matter: it must not leak the secret into a log, it must fail loudly when the
# workflow forgot `id-token: write`, and it must do nothing at all when no role is configured.

load helper

setup() {
  setup_common
  export GITHUB_REPOSITORY=MagmaMoose/website
  export GITHUB_RUN_ID=12345
  export ACTIONS_ID_TOKEN_REQUEST_URL='https://token.test/?foo=bar'
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-token
  export ROLE_TO_ASSUME=arn:aws:iam::111111111111:role/deploy

  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
printf '{"value":"%s"}' "${OIDC_TOKEN-header.payload.signature}"
STUBEOF

  stub_script aws <<'STUBEOF'
#!/usr/bin/env bash
printf 'aws %s\n' "$*" >>"${STUB_LOG}"
case "$*" in
  *assume-role-with-web-identity*)
    [ "${STS_FAILS:-false}" = "true" ] && exit 254
    printf '{"AccessKeyId":"ASIAEXAMPLE","SecretAccessKey":"s3cr3t-key","SessionToken":"sess10n-token"}' ;;
  *get-caller-identity*) printf 'arn:aws:sts::111111111111:assumed-role/deploy/tremvok' ;;
esac
exit 0
STUBEOF
}

@test "no role configured is a no-op, not a failure" {
  ROLE_TO_ASSUME= run bash "${SCRIPTS}/assume-role.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
  [ ! -s "$GITHUB_ENV" ]
}

@test "a role without id-token: write fails with the fix in the message" {
  ACTIONS_ID_TOKEN_REQUEST_URL= run bash "${SCRIPTS}/assume-role.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"id-token: write"* ]]
}

@test "the credentials are masked before they are exported" {
  # Without ::add-mask::, a later step that dumps its environment — or a tool that prints its
  # config on error — writes the secret into a log anyone with read access keeps forever.
  run bash "${SCRIPTS}/assume-role.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::add-mask::s3cr3t-key"* ]]
  [[ "$output" == *"::add-mask::sess10n-token"* ]]
}

@test "the mask is emitted before the value reaches GITHUB_ENV" {
  run bash "${SCRIPTS}/assume-role.sh"
  [ "$status" -eq 0 ]
  # Masking after exporting would be a race the log always wins.
  grep -q 'AWS_SECRET_ACCESS_KEY=s3cr3t-key' "$GITHUB_ENV"
  [[ "$output" == *"::add-mask::s3cr3t-key"* ]]
}

@test "the assumed credentials are written for later steps" {
  AWS_REGION=eu-west-1 run bash "${SCRIPTS}/assume-role.sh"
  [ "$status" -eq 0 ]
  grep -q 'AWS_ACCESS_KEY_ID=ASIAEXAMPLE' "$GITHUB_ENV"
  grep -q 'AWS_SESSION_TOKEN=sess10n-token' "$GITHUB_ENV"
  grep -q 'AWS_REGION=eu-west-1' "$GITHUB_ENV"
  grep -q 'AWS_DEFAULT_REGION=eu-west-1' "$GITHUB_ENV"
}

@test "the OIDC token is requested for the sts audience" {
  run bash "${SCRIPTS}/assume-role.sh"
  grep -q 'audience=sts.amazonaws.com' "$STUB_LOG"
}

@test "the session name is STS-legal: no slash, at most 64 characters" {
  # A repository name always contains '/', which STS rejects outright, and the cap is 64.
  GITHUB_REPOSITORY=MagmaMoose/a-very-long-repository-name-that-keeps-going-and-going-and-going \
    run bash "${SCRIPTS}/assume-role.sh"
  [ "$status" -eq 0 ]
  session="$(grep -oE '\-\-role-session-name [^ ]+' "$STUB_LOG" | head -1 | cut -d' ' -f2)"
  [ -n "$session" ]
  [ "${#session}" -le 64 ]
  [[ "$session" != */* ]]
}

@test "an STS refusal fails with the trust policy named" {
  STS_FAILS=true run bash "${SCRIPTS}/assume-role.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"trust policy"* ]]
}

@test "an empty OIDC token fails rather than assuming with nothing" {
  OIDC_TOKEN= run bash "${SCRIPTS}/assume-role.sh"
  [ "$status" -ne 0 ]
}
