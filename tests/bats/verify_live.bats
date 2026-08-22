#!/usr/bin/env bats

load helper

setup() {
  setup_common
  # A `curl` that writes the headers file the script asked for and prints a status code.
  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
headers=""
prev=""
for arg in "$@"; do
  [ "$prev" = "--dump-header" ] && headers="$arg"
  prev="$arg"
done
[ -n "$headers" ] && printf '%s' "${RESPONSE_HEADERS:-HTTP/2 200}" >"$headers"
printf '%s' "${RESPONSE_STATUS:-200}"
exit 0
STUBEOF
}

@test "no verify-url means verification is skipped, not failed" {
  run bash "${SCRIPTS}/verify-live.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value verified)" = "false" ]
  [ "$(output_value verify-skipped)" = "true" ]
}

@test "a 200 verifies" {
  VERIFY_URL=https://magmamoose.com/ run bash "${SCRIPTS}/verify-live.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value verified)" = "true" ]
}

@test "a non-200 fails after retrying" {
  RESPONSE_STATUS=503 VERIFY_URL=https://magmamoose.com/ ATTEMPTS=2 DELAY=0 \
    run bash "${SCRIPTS}/verify-live.sh"
  [ "$status" -ne 0 ]
  [ "$(output_value verified)" = "false" ]
  [ "$(grep -c '^curl' "$STUB_LOG")" -eq 2 ]
}

@test "an unreachable host is a failure, not a pass" {
  RESPONSE_STATUS=000 VERIFY_URL=https://magmamoose.com/ ATTEMPTS=1 DELAY=0 \
    run bash "${SCRIPTS}/verify-live.sh"
  [ "$status" -ne 0 ]
}

@test "a missing required header fails even when the status is 200" {
  # This is the dunmir case: uploaded but not bound. The apex answers 200 from the OLD
  # version, so status alone cannot tell you the deploy landed.
  RESPONSE_HEADERS="HTTP/2 200
server: nginx" VERIFY_URL=https://magmamoose.com/ VERIFY_HEADER=content-security-policy \
    ATTEMPTS=1 DELAY=0 run bash "${SCRIPTS}/verify-live.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"header is absent"* ]]
}

@test "header matching is case-insensitive, because HTTP/2 lower-cases names" {
  RESPONSE_HEADERS="HTTP/1.1 200 OK
Content-Security-Policy: default-src 'self'" \
    VERIFY_URL=https://magmamoose.com/ VERIFY_HEADER=content-security-policy \
    run bash "${SCRIPTS}/verify-live.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value verified)" = "true" ]
}

@test "a header value can be required to match a pattern" {
  RESPONSE_HEADERS="HTTP/2 200
content-security-policy: default-src 'none'" \
    VERIFY_URL=https://magmamoose.com/ VERIFY_HEADER=content-security-policy \
    VERIFY_HEADER_MATCH="default-src 'self'" ATTEMPTS=1 DELAY=0 \
    run bash "${SCRIPTS}/verify-live.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match"* ]]
}

@test "a non-http verify-url is refused rather than curled" {
  VERIFY_URL="file:///etc/passwd" run bash "${SCRIPTS}/verify-live.sh"
  [ "$status" -ne 0 ]
  [ ! -s "$STUB_LOG" ]
}

@test "a transient failure that recovers still verifies" {
  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl\n' >>"${STUB_LOG}"
headers=""; prev=""
for arg in "$@"; do [ "$prev" = "--dump-header" ] && headers="$arg"; prev="$arg"; done
[ -n "$headers" ] && printf 'HTTP/2 200' >"$headers"
if [ "$(grep -c curl "${STUB_LOG}")" -lt 3 ]; then printf '502'; else printf '200'; fi
STUBEOF
  VERIFY_URL=https://magmamoose.com/ ATTEMPTS=5 DELAY=0 run bash "${SCRIPTS}/verify-live.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value verified)" = "true" ]
}
