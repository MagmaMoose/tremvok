#!/usr/bin/env bash
# Read one secret out of HashiCorp Vault and print it on stdout.
#
# Exists so a caller does not have to choose between two bad options: copying a secret that
# already lives in Vault into a second store, where rotating the original silently stops
# rotating the copy, or hand-rolling a `curl | jq` step in front of every workflow that needs
# one. The value is printed and nothing else, so the caller decides what to mask and where to
# write it.
#
# The reference is `<path>#<field>`, e.g.
#
#   secret/data/all/common/ansible/linux#ssh_private_key
#
# KV v2 nests the payload one level deeper than v1 (`.data.data.<field>` rather than
# `.data.<field>`). Both are tried rather than asking the caller to declare which engine they
# are on, because the mount version is not visible from the path in every layout and getting
# it wrong reads as "field not found" rather than "wrong API shape".
#
# **Nothing here goes to stderr on the happy path, and the value never reaches a log.** A
# failure names the path and the HTTP status; it never echoes the response body, which on a
# partial failure can contain the secret.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-}"
reference="${1:-}"

[[ -n "$reference" ]] || tremvok::fail "vault-read.sh needs a <path>#<field> reference"
tremvok::require VAULT_ADDR "vault-addr"
tremvok::require VAULT_TOKEN "vault-token"

case "$reference" in
  *'#'*) ;;
  *) tremvok::fail "vault reference '${reference}' has no '#<field>'. Use <path>#<field>, e.g. secret/data/team/app#ssh_private_key" ;;
esac

path="${reference%%#*}"
field="${reference##*#}"
[[ -n "$path" && -n "$field" ]] || tremvok::fail "vault reference '${reference}' must be <path>#<field>, both non-empty"

# A leading slash on the path doubles the one in the URL and Vault answers 404 for a secret
# that is plainly there, which is a confusing five minutes.
path="${path#/}"

body_file="$(mktemp)"
config_file="$(mktemp)"
trap 'rm -f "$body_file" "$config_file"' EXIT

# Write headers to a curl config file rather than argv so the token never appears in
# /proc/PID/cmdline, which is readable by co-located processes on a shared self-hosted runner.
printf 'header = "X-Vault-Token: %s"\n' "$VAULT_TOKEN" > "$config_file"
[[ -n "$VAULT_NAMESPACE" ]] && printf 'header = "X-Vault-Namespace: %s"\n' "$VAULT_NAMESPACE" >> "$config_file"

status="$(curl -sS --retry 2 --max-time 30 -o "$body_file" -w '%{http_code}' \
  -K "$config_file" "${VAULT_ADDR%/}/v1/${path}" || printf '000')"

case "$status" in
  200) ;;
  000) tremvok::fail "cannot reach Vault at ${VAULT_ADDR%/} (no response). From a private network this usually means the runner is not on it." ;;
  403) tremvok::fail "Vault refused the token for '${path}' (403). The token is valid but its policy does not grant read on that path." ;;
  404) tremvok::fail "Vault has nothing at '${path}' (404). On a KV v2 mount the path needs the '/data/' segment, e.g. secret/data/team/app rather than secret/team/app." ;;
  *) tremvok::fail "Vault returned HTTP ${status} for '${path}'" ;;
esac

# KV v2 first, then v1. `// empty` rather than `// null` so a missing field is an empty
# capture rather than the four characters "null" written into a private key file.
value="$(jq -r --arg f "$field" '.data.data[$f] // empty' <"$body_file")"
if [[ -z "$value" ]]; then
  value="$(jq -r --arg f "$field" '.data[$f] // empty' <"$body_file")"
fi

if [[ -z "$value" ]]; then
  # The field list is safe to show and is almost always what the reader needs; the values
  # are not, and are not shown.
  available="$(jq -r '(.data.data // .data // {}) | keys | join(", ")' <"$body_file" 2>/dev/null || printf '<unreadable>')"
  tremvok::fail "Vault has '${path}' but no field '${field}' in it. Fields present: ${available}"
fi

printf '%s' "$value"
