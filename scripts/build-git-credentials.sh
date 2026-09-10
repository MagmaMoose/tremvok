#!/usr/bin/env bash
# Let the build fetch a dependency from a private git host, and leave nothing behind.
#
# A site build often installs a dependency straight out of a private repository — an MkDocs
# theme pinned as `pkg @ git+https://<host>/<org>/<repo>.git@<tag>` in a requirements file, a
# private package resolved by a `git+https` URL in a lockfile. The clone is git's own, several
# processes below this action, so there is no flag to pass a token on: it has to be waiting in
# the environment git reads.
#
# `GIT_CONFIG_COUNT` with `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n` is that environment. Each
# pair is one config entry, and the entry written here is a `url.<credentialled>.insteadOf`
# rewrite: git sees `https://<host>/` in the dependency URL and substitutes the form carrying
# the token. The requirements file stays clean and stays reviewable, which it would not if the
# credential had to be pasted into the URL it pins.
#
# **Never `git config --global`.** It would work, and it writes the token into `~/.gitconfig`
# on the runner. A self-hosted runner is a shared, long-lived machine: that file and the
# credential in it outlive this job, and are read by whatever runs on the box next. These
# variables live in the job's environment and go away with the job.
#
# Nothing from this input is ever echoed. Every token is registered with `::add-mask::` on
# receipt, before a single check can fail, and a malformed line is named by its INDEX and its
# host, never by its content. The precedent is `stack_env_glob_label` in deploy-terragrunt.sh:
# a field is only quoted when it looks like the thing it claims to be, because naming a line
# by cutting it at its separator once printed a key almost in full. Nothing is written to the
# step summary either — the log says everything there is to say, and every extra place a token
# could reach is one more place to get it wrong.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

BUILD_GIT_CREDENTIALS="${BUILD_GIT_CREDENTIALS:-}"

# Below this, a token is refused rather than used. See mask_token.
MIN_TOKEN_LENGTH=8

# The YAML `if:` gates this step too; the script stands alone because bats calls it directly.
if [[ -z "${BUILD_GIT_CREDENTIALS//[[:space:]]/}" ]]; then
  tremvok::log "no build-git-credentials set; the build's git configuration is untouched"
  exit 0
fi

# Unlike assume-role.sh there is no in-shell fallback to fall back to: the fetch happens in a
# LATER step, so with no GITHUB_ENV this input silently does nothing and the build fails
# minutes later with git's own "Authentication failed", which names neither the input nor the
# reason.
[[ -n "${GITHUB_ENV:-}" ]] \
  || tremvok::fail "GITHUB_ENV is not set, so build-git-credentials has nowhere to put the rewrite the build needs. This script runs as a GitHub Actions step."

# Registers a value as a secret for the rest of the job. Two rules that are easy to miss:
#
#   * The runner percent-decodes a workflow command's data, so a `%` in the value would
#     register a mask that is not the value — and the value itself would then print in full,
#     which is the opposite of what this call is for. Encoded before it is emitted.
#   * Under MIN_TOKEN_LENGTH characters, nothing is masked. `::add-mask::ab` replaces every
#     "ab" in every later line of the log with asterisks, which ruins the log and protects
#     nothing: a string that short is a word, not a credential. Such a line is refused below,
#     so this only decides what a doomed line does on its way to the refusal.
mask_token() { # value
  local value="$1"
  (( ${#value} >= MIN_TOKEN_LENGTH )) || return 0
  printf '::add-mask::%s\n' "${value//%/%25}"
  return 0
}

# The host half, named rather than printed, following stack_env_glob_label in
# deploy-terragrunt.sh. Only what looks like a host is quoted.
host_label() { # field
  local residue
  case "$1" in
    "") printf '%s' 'an empty host' ;;
    # `host:port` and the `<username>:<token>` half pasted on its own are the same shape and
    # cannot be told apart. The one that must never be printed decides for both.
    *:*) printf '%s' 'not a bare host (it has a ":" in it), so it is named by line number only' ;;
    # Positive test, not a blocklist. A forge host carries a dot and nothing but host
    # characters; a token has no dot, and a short word is indistinguishable from a short
    # secret.
    *.*)
      residue="$(printf '%s' "$1" | tr -d 'A-Za-z0-9.-')"
      if [[ -n "$residue" ]]; then
        printf '%s' 'not a host name (it holds characters a host cannot), so it is named by line number only'
      elif (( ${#1} > 64 )); then
        printf '%s' 'not a host name (too long to be one), so it is named by line number only'
      else
        printf "'%s'" "$1"
      fi
      ;;
    *) printf '%s' 'not a host name (no "." in it), so it is named by line number only' ;;
  esac
  return 0
}

# Extended, not overwritten. An earlier step of the caller's job may already have written
# rewrites of its own, and starting again at 0 would replace them with these — silently, since
# git reads indices 0 to GIT_CONFIG_COUNT-1 and never says which entry it lost.
index="${GIT_CONFIG_COUNT:-0}"
case "$index" in
  '' | *[!0-9]*)
    tremvok::fail "GIT_CONFIG_COUNT holds '${index}', which is not a number, so the git configuration this step would extend cannot be read. Fix or unset it before calling Tremvok."
    ;;
esac

line_number=0
configured=0
hosts=""
labels=""

# Parsing follows stack_env_for() in deploy-terragrunt.sh: trim, skip blanks and `#` comments,
# one `<selector> <payload>` per line. The selector is the host; the payload is the credential.
while IFS= read -r line; do
  # Counted before the skips, so the number names the line the caller actually typed.
  line_number=$(( line_number + 1 ))
  line="${line#"${line%%[![:space:]]*}"}"
  # Trailing whitespace too, which is what a workflow file with CRLF line endings leaves on
  # the end of every token in a YAML block scalar.
  line="${line%"${line##*[![:space:]]}"}"
  [[ -n "$line" && "$line" != '#'* ]] || continue

  host="${line%%[[:space:]]*}"
  credential="${line#"$host"}"
  credential="${credential#"${credential%%[![:space:]]*}"}"

  # Masked on receipt, before any check below can fail and name this line. Both halves: the
  # `<username>:<token>` field whole, and the token on its own, because a mask registered for
  # the pair does not cover a later log line that printed only the token.
  mask_token "$credential"
  mask_token "${credential#*:}"

  case "$host" in
    *://* | */*)
      tremvok::fail "build-git-credentials line ${line_number} starts with a URL, not a host. Write the bare host and let the rewrite be built from it. The line is named by index alone: one in the wrong shape may be a credential."
      ;;
  esac
  residue="$(printf '%s' "$host" | tr -d 'A-Za-z0-9.:-')"
  [[ -z "$residue" ]] \
    || tremvok::fail "build-git-credentials line ${line_number} does not start with a host: it holds characters a host name cannot. One \`<host> <username>:<token>\` per line. The line is named by index alone, because what is in that field may be a credential."

  [[ -n "$credential" ]] \
    || tremvok::fail "build-git-credentials line ${line_number} is a host with nothing after it: $(host_label "$host"). One \`<host> <username>:<token>\` per line."

  case "$credential" in
    *[[:space:]]*)
      tremvok::fail "build-git-credentials line ${line_number} has a third field after the credential, for host $(host_label "$host"). A line is exactly \`<host> <username>:<token>\`, and nothing at or after the ':' is ever printed."
      ;;
  esac

  case "$credential" in
    *:*) ;;
    *)
      tremvok::fail "build-git-credentials line ${line_number} has no ':' between the username and the token, for host $(host_label "$host"). Write \`<host> <username>:<token>\`: x-access-token for a GitHub App token, oauth2 for a GitLab one. The token is never printed, so it is not shown here."
      ;;
  esac

  # Split at the FIRST ':'. That is deliberate and it is the safe way round: the username is
  # the half that cannot contain a colon (every forge's is a fixed literal), so a token that
  # holds one survives intact in the tail. Splitting at the last ':' would cut a token in the
  # middle, which is the mistake stack_env_glob_label exists because of.
  username="${credential%%:*}"
  token="${credential#*:}"

  [[ -n "$username" ]] \
    || tremvok::fail "build-git-credentials line ${line_number} has nothing before the ':', for host $(host_label "$host"). The username is required: x-access-token for a GitHub App token, oauth2 for a GitLab one."
  [[ -n "$token" ]] \
    || tremvok::fail "build-git-credentials line ${line_number} has nothing after the ':', for host $(host_label "$host")."
  (( ${#token} >= MIN_TOKEN_LENGTH )) \
    || tremvok::fail "build-git-credentials line ${line_number} has a token under ${MIN_TOKEN_LENGTH} characters, for host $(host_label "$host"). It is refused rather than used: a real token is never that short, so this is a truncated paste, and masking a string that short would replace every occurrence of it in every later line of the log."

  case " ${hosts} " in
    *" ${host} "*)
      tremvok::fail "build-git-credentials names host $(host_label "$host") twice, again on line ${line_number}. Which of two rewrites for one host git picks is not defined, so the credential in use would not be the one you can read off the input."
      ;;
  esac
  hosts="${hosts}${host} "
  labels="${labels}${labels:+, }$(host_label "$host")"

  # Written as they are read; GIT_CONFIG_COUNT is written once, at the end. git reads indices
  # 0 to COUNT-1 and ignores the rest, so a line refused halfway through leaves the entries
  # above the old count inert and the configuration the job already had exactly as it was.
  {
    printf 'GIT_CONFIG_KEY_%s=url.https://%s:%s@%s/.insteadOf\n' "$index" "$username" "$token" "$host"
    printf 'GIT_CONFIG_VALUE_%s=https://%s/\n' "$index" "$host"
  } >>"$GITHUB_ENV"
  index=$(( index + 1 ))
  configured=$(( configured + 1 ))
done <<<"$BUILD_GIT_CREDENTIALS"

if (( configured == 0 )); then
  tremvok::log "build-git-credentials holds only blank lines and comments; the build's git configuration is untouched"
  exit 0
fi

printf 'GIT_CONFIG_COUNT=%s\n' "$index" >>"$GITHUB_ENV"

# The hosts, by the same rule the refusals use: one that cannot be named safely says so. That
# is the case where you most want to be told, because the fetch is about to fail against a
# host nobody can read off the log.
tremvok::log "configured ${configured} private git host(s) for this build: ${labels}"
tremvok::log "the rewrites live in this job's environment only, never in ~/.gitconfig"
