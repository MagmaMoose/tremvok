#!/usr/bin/env bash
# Is anything listening at the endpoints this run needs, before the first plan?
#
# Terragrunt buffers every invocation's output to a file, so a state backend or a provider API
# the runner cannot reach is not an error: it is a silent wait until `terragrunt-timeout`
# (900 seconds by default) with nothing on screen. One bounded request per URL turns fifteen
# minutes of nothing into a red step in eight seconds, naming the endpoint.
#
# **This proves reachability, not authorisation.** Any HTTP status passes, 401 and 403
# included: an unauthenticated probe of a credentialed endpoint is *supposed* to be refused,
# and being refused is proof something is there. A 403 does not mean the credential works.
# Only curl code 000 fails, which is DNS, connection refused, a connect timeout, a TLS
# handshake failure, a proxy refusal or `--max-time` expiring — exactly the shape that stalls.
#
# Deliberately NOT verify-live.sh, and deliberately not scripts/preflight.sh:
#   * verify-live.sh asks whether ONE url answers ONE expected status, retries six times for
#     CDN propagation, and writes outputs the notify path consumes. Retrying here would be the
#     multi-minute wait this check exists to replace.
#   * preflight.sh decides whether a run can deploy at all, and its answer is a *soft* skip
#     that every later step reads. This one is a hard failure. One script cannot own both.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

PREFLIGHT_URLS="${PREFLIGHT_URLS:-}"
# Env-only, not inputs: a knob nobody turns is public surface for nothing. Promote either if
# it actually bites.
PROBE_TIMEOUT="${PROBE_TIMEOUT:-8}"
EGRESS_IP_URL="${EGRESS_IP_URL:-https://api.ipify.org}"

# The YAML `if:` also gates this step, but the script stands alone because bats calls it
# directly and a caller may too.
if [[ -z "${PREFLIGHT_URLS//[[:space:]]/}" ]]; then
  tremvok::log "no terragrunt-preflight-urls set; skipping the reachability preflight"
  exit 0
fi

# GitHub-hosted runners always have curl; a self-hosted one might not, and that should say so
# rather than report every endpoint as unreachable.
command -v curl >/dev/null \
  || tremvok::fail "curl is required for the reachability preflight"

# `curl --max-time 0` means NO limit, which reintroduces the hang this check exists to catch.
# Deliberately unlike terragrunt-timeout, where 0 does mean "disable".
case "$PROBE_TIMEOUT" in
  '' | *[!0-9]*) tremvok::fail "PROBE_TIMEOUT must be a positive whole number of seconds (got '${PROBE_TIMEOUT}')" ;;
esac
(( PROBE_TIMEOUT > 0 )) \
  || tremvok::fail "PROBE_TIMEOUT must be greater than 0: curl --max-time 0 is unlimited, which is the hang this check exists to catch."

total=0
failures=0
unreachable=""

# ── nothing from this input is ever echoed raw ───────────────────────────────────────────
# A guard that refuses a credential-bearing URL by printing the credential is worse than no
# guard: the ::error:: annotation and the step summary are as public as the repository. Every
# message below names the LINE INDEX and a redacted form, never the line.
#
# The userinfo is what is replaced (`https://user:password@host/path`), because that is the
# part this file refuses over. The rest of the URL is kept: without a host and a path the
# message cannot tell anyone which endpoint it is about, which is the whole job.
redact_url() { # url
  local url="$1" scheme rest authority remainder
  case "$url" in
    *://*) ;;
    *) printf '%s' '(not a URL)'; return 0 ;;
  esac
  scheme="${url%%://*}"
  rest="${url#*://}"
  authority="${rest%%/*}"
  case "$rest" in
    */*) remainder="/${rest#*/}" ;;
    *) remainder="" ;;
  esac
  case "$authority" in
    # `##`, not `#`. curl reads userinfo up to the LAST `@` in the authority, so a password
    # that itself contains one (a `p@ss`, an email as the username) leaves the tail of that
    # password in the host slot under a shortest match, which is the leak this exists to stop.
    *@*) printf '%s://%s@%s%s' "$scheme" '<redacted>' "${authority##*@}" "$remainder" ;;
    *) printf '%s' "$url" ;;
  esac
  return 0
}

# For a line that is not an http(s) URL at all there is no safe part to show: it could be
# anything, including a secret pasted into the wrong input. The scheme is enough to say what
# is wrong, and only when it looks like a scheme.
scheme_label() { # line
  local candidate residue
  case "$1" in
    *://*)
      # Not a glob. `[A-Za-z][A-Za-z0-9+.-]*` looks like a scheme pattern and is not one: in a
      # glob the trailing `*` matches ANY characters, so `ht tp://secret` matched and printed
      # the line back. Delete every character a scheme may contain and require nothing left.
      candidate="${1%%://*}"
      residue="$(printf '%s' "$candidate" | tr -d 'A-Za-z0-9+.-')"
      case "$candidate" in
        [A-Za-z]*)
          if [[ -z "$residue" ]]; then
            printf '%s://' "$candidate"
          else
            printf '%s' 'an unrecognised scheme'
          fi
          ;;
        *) printf '%s' 'an unrecognised scheme' ;;
      esac
      ;;
    *) printf '%s' 'no scheme at all' ;;
  esac
  return 0
}

# One request, no retry, no redirect following. A redirect already proves the near end
# answered, and following one can land on an identity provider several seconds away and turn a
# bounded probe into a chain.
#
# Ends `return 0` on every path: a `case` whose last arm is a false test would otherwise be
# this function's exit status, and under `set -e` that kills the run.
probe_one() { # url
  local url="$1" out code seconds rc=0 shown
  # Redacted even here, where the loop has already refused anything carrying userinfo: a
  # printf of a raw input line is the thing that must not exist in this file at all.
  shown="$(redact_url "$url")"
  # `&& rc=0 || rc=$?` keeps the assignment inside a compound list so errexit cannot kill the
  # script, and captures curl's own exit code, which is what distinguishes DNS (6) from
  # refused (7) from timeout (28) from TLS (35/60).
  # `</dev/null` so curl cannot eat the loop's stdin, which is the URL list being read.
  out="$(curl --silent --show-error --output /dev/null \
           --max-time "$PROBE_TIMEOUT" \
           --write-out '%{http_code} %{time_total}' \
           "$url" </dev/null 2>/dev/null)" && rc=0 || rc=$?

  code="${out%% *}"
  seconds="${out##* }"
  # Anything unparsable or empty is treated as 000, which is the safe side.
  case "$code" in
    '' | *[!0-9]*) code="000" ;;
  esac
  case "$seconds" in
    '' | *[!0-9.]*) seconds="0" ;;
  esac

  printf '%-52s -> %s in %ss\n' "$shown" "$code" "$seconds"

  case "$code" in
    000)
      printf '  ^ UNREACHABLE (curl exit %s). This is the shape that stalls a plan instead of failing it.\n' "$rc"
      failures=$(( failures + 1 ))
      unreachable="${unreachable}${shown}"$'\n'
      ;;
    401 | 403)
      # The rule most likely to be "fixed" by somebody who does not know it, so it is stated
      # in the input description, on this line, and in a test name.
      printf '  ^ reachable. An unauthenticated probe of a credentialed endpoint is supposed to be refused, so this is proof of life, not proof the credential works.\n'
      ;;
    5*)
      # A 502 or 503 from a load balancer still proves DNS, routing and TLS. Failing on it
      # would make this a flake source, and a flaky guard gets deleted.
      tremvok::warn "${shown} answered ${code}. Reachable, so the preflight passes: the endpoint is up but unhappy."
      ;;
    4*)
      printf '  ^ reachable. The path may be wrong, the network is not.\n'
      ;;
    *) ;;
  esac
  return 0
}

# Failure-isolated in the same sense as the notification sinks: it prints `unknown` when it
# cannot resolve and never changes the exit status. Only on the failure path, because on a
# clean run it is unread noise and an unnecessary call to a third party.
print_egress_ip() {
  local ip=""
  [[ -n "$EGRESS_IP_URL" ]] || return 0
  ip="$(curl --silent --show-error --max-time 5 "$EGRESS_IP_URL" 2>/dev/null)" || ip=""
  case "$ip" in
    '' | *[!0-9a-fA-F.:]*) ip="unknown" ;;
  esac
  printf 'runner egress IP: %s (if an endpoint above is IP-allowlisted, this is the address to allow)\n' "$ip"
  return 0
}

# Parsing follows stack_env_for() in deploy-terragrunt.sh: trim, skip blanks and `#` comments.
# One bare URL per line — the URL is already the label, and leaving the first token free keeps
# `<url> <label>` available as an additive extension later.
index=0
while IFS= read -r line; do
  # Counted before the skips, so the number names the line the caller actually typed.
  index=$(( index + 1 ))
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -n "$line" && "$line" != '#'* ]] || continue

  case "$line" in
    https://*|http://*) ;; # DevSkim: ignore DS137138 - case pattern, not an http call
    *) tremvok::fail "terragrunt-preflight-urls line ${index} is not an http(s) URL: it has $(scheme_label "$line"). One bare URL per line; curl would guess a scheme for a bare hostname and quietly probe something else. The line is named by index and not printed, because a line in the wrong input may be a secret." ;;
  esac

  # Every probe URL is printed into a run log, which is public on a public repository.
  authority="${line#*://}"
  authority="${authority%%/*}"
  case "$authority" in
    *@*) tremvok::fail "terragrunt-preflight-urls line ${index} carries credentials in the URL: $(redact_url "$line"). These lines are printed into the run log; put nothing secret in them." ;;
  esac

  total=$(( total + 1 ))
  # No dedupe: a probe is cheap, and silently collapsing a copy/paste mistake hides it.
  # No early exit either, so one run names every broken endpoint rather than one per attempt.
  probe_one "$line"
done <<<"$PREFLIGHT_URLS"

if (( total == 0 )); then
  tremvok::log "terragrunt-preflight-urls holds only blank lines and comments; nothing to probe"
  exit 0
fi

if (( failures > 0 )); then
  print_egress_ip
  tremvok::summary "## Tremvok, an endpoint is unreachable"
  tremvok::summary ""
  tremvok::summary "${failures} of ${total} preflight endpoint(s) did not answer from this runner:"
  tremvok::summary ""
  while IFS= read -r bad; do
    [[ -n "$bad" ]] || continue
    tremvok::summary "- \`${bad}\`"
  done <<<"$unreachable"
  tremvok::fail "${failures} of ${total} preflight endpoints are unreachable from this runner. Terragrunt buffers plan output to a file, so an unreachable state backend or provider API is a silent wait until terragrunt-timeout (900s by default) rather than an error."
fi

tremvok::log "all ${total} preflight endpoint(s) answered"
