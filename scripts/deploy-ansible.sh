#!/usr/bin/env bash
# The Ansible target: install a pinned Ansible, run a playbook over SSH, then prove the run
# converged.
#
# Why this exists as a deployment target at all: a fleet of hosts reachable only from inside
# a private network, whose CI runner account has no passwordless sudo, cannot have its
# OS-level dependencies installed by a workflow job. Configuration management over SSH,
# triggered from a workflow, is the only shape that fits — so it is a first-class target
# rather than a script someone pastes into a job.
#
# Two things here are not negotiable:
#
#   * **Secrets never reach a log.** The SSH key and the vault password are masked on receipt
#     and written to 0600 files under $RUNNER_TEMP, removed by a trap that fires however the
#     script exits. Nothing is passed on a command line, where `ps` and `set -x` would both
#     expose it.
#   * **A zero exit is not proof.** It proves the playbook ran. Running it a second time in
#     check mode and asserting that nothing would still change is what proves it converged —
#     the same argument as verifying a deployed URL actually answers.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ANSIBLE_VERSION="${ANSIBLE_VERSION:-}"
PLAYBOOK="${PLAYBOOK:-}"
INVENTORY="${INVENTORY:-}"
GALAXY_REQUIREMENTS="${GALAXY_REQUIREMENTS:-}"
LIMIT="${LIMIT:-}"
TAGS="${TAGS:-}"
SKIP_TAGS="${SKIP_TAGS:-}"
CHECK="${CHECK:-auto}"
DIFF="${DIFF:-true}"
EXTRA_VARS="${EXTRA_VARS:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-}"
SSH_USER="${SSH_USER:-}"
SSH_KNOWN_HOSTS="${SSH_KNOWN_HOSTS:-}"
VAULT_PASSWORD="${VAULT_PASSWORD:-}"
VERIFY_IDEMPOTENCE="${VERIFY_IDEMPOTENCE:-true}"
EVENT_NAME="${EVENT_NAME:-}"
DRY_RUN="${DRY_RUN:-false}"
PIP="${PIP:-pip}"
ANSIBLE_PLAYBOOK_BIN="${ANSIBLE_PLAYBOOK_BIN:-ansible-playbook}"
ANSIBLE_GALAXY_BIN="${ANSIBLE_GALAXY_BIN:-ansible-galaxy}"

tremvok::require PLAYBOOK "ansible-playbook is the path to the playbook to run"
tremvok::require INVENTORY "ansible-inventory is the inventory passed to -i"
[[ -f "$PLAYBOOK" ]] || tremvok::fail "no playbook at ${PLAYBOOK} (working directory: ${PWD})"

# ── check mode ───────────────────────────────────────────────────────────────────────────
# A pull request that silently reconfigured a fleet would be a surprising way to find out
# what a diff does, so `auto` means check mode on a pull request and a real run everywhere
# else. dry-run forces it regardless.
case "$CHECK" in
  true) check_mode=true ;;
  false) check_mode=false ;;
  auto) check_mode=false; [[ "$EVENT_NAME" == pull_request || "$EVENT_NAME" == pull_request_target ]] && check_mode=true ;;
  *) tremvok::fail "ansible-check must be auto, true or false (got '${CHECK}')" ;;
esac
tremvok::is_true "$DRY_RUN" && check_mode=true

# ── secrets, on disk and nowhere else ────────────────────────────────────────────────────
work="${RUNNER_TEMP:-/tmp}/tremvok-ansible.$$"
mkdir -p "$work"
chmod 700 "$work"
# Fires on success, on failure and on an interrupt. A key left behind on a self-hosted
# runner outlives the job, and self-hosted runners are exactly what this target is for.
trap 'rm -rf "$work"' EXIT INT TERM

# GitHub masks per LINE, so a multi-line PEM has to be masked line by line: masking the
# whole value only hides a string that never appears whole in one log line.
mask_every_line() {
  while IFS= read -r line; do
    [[ ${#line} -ge 8 ]] || continue
    printf '::add-mask::%s\n' "$line"
  done <<<"$1"
}

key_file=""
if [[ -n "$SSH_PRIVATE_KEY" ]]; then
  mask_every_line "$SSH_PRIVATE_KEY"
  key_file="${work}/id_key"
  # The trailing newline is unconditional: OpenSSH rejects a key file without one, and a
  # repository secret often loses it. A doubled newline is harmless, a missing one is not.
  ( umask 077; printf '%s\n' "$SSH_PRIVATE_KEY" >"$key_file" )
  tremvok::log "ssh key written to a 0600 file for this step only"
fi

vault_file=""
if [[ -n "$VAULT_PASSWORD" ]]; then
  printf '::add-mask::%s\n' "$VAULT_PASSWORD"
  vault_file="${work}/vault-pass"
  ( umask 077; printf '%s' "$VAULT_PASSWORD" >"$vault_file" )
fi

if [[ -n "$SSH_KNOWN_HOSTS" ]]; then
  known_hosts="${work}/known_hosts"
  printf '%s\n' "$SSH_KNOWN_HOSTS" >"$known_hosts"
  export ANSIBLE_HOST_KEY_CHECKING=True
  export ANSIBLE_SSH_COMMON_ARGS="-o UserKnownHostsFile=${known_hosts} -o StrictHostKeyChecking=yes"
else
  # Named out loud because it is a real downgrade, not a default worth being quiet about.
  tremvok::warn "no ansible-ssh-known-hosts supplied, so host-key checking is off for this run. Supply it for anything reachable from a network you do not control."
  export ANSIBLE_HOST_KEY_CHECKING=False
fi

# Ansible's own output is the thing most likely to carry a secret into a log. `no_log:` in
# the playbook is the primary protection; this is the belt.
export ANSIBLE_FORCE_COLOR=0
export ANSIBLE_NOCOWS=1

# ── install, pinned ──────────────────────────────────────────────────────────────────────
if [[ -n "$ANSIBLE_VERSION" ]] && ! tremvok::is_true "${TREMVOK_SKIP_INSTALL:-false}"; then
  tremvok::log "installing ansible==${ANSIBLE_VERSION}"
  $PIP install --disable-pip-version-check --quiet "ansible==${ANSIBLE_VERSION}"
fi

if [[ -n "$GALAXY_REQUIREMENTS" ]]; then
  [[ -f "$GALAXY_REQUIREMENTS" ]] \
    || tremvok::fail "no galaxy requirements file at ${GALAXY_REQUIREMENTS}"
  tremvok::log "installing galaxy requirements from ${GALAXY_REQUIREMENTS}"
  $ANSIBLE_GALAXY_BIN install -r "$GALAXY_REQUIREMENTS"
fi

# ── the run ──────────────────────────────────────────────────────────────────────────────
# shellcheck disable=SC2206  # deliberate word splitting: EXTRA_ARGS is a flag string
extra=( $EXTRA_ARGS )

base_args=( -i "$INVENTORY" )
[[ -n "$LIMIT" ]] && base_args+=( --limit "$LIMIT" )
[[ -n "$TAGS" ]] && base_args+=( --tags "$TAGS" )
[[ -n "$SKIP_TAGS" ]] && base_args+=( --skip-tags "$SKIP_TAGS" )
[[ -n "$SSH_USER" ]] && base_args+=( --user "$SSH_USER" )
[[ -n "$key_file" ]] && base_args+=( --private-key "$key_file" )
[[ -n "$vault_file" ]] && base_args+=( --vault-password-file "$vault_file" )
[[ -n "$EXTRA_VARS" ]] && base_args+=( --extra-vars "$EXTRA_VARS" )
tremvok::is_true "$DIFF" && base_args+=( --diff )

# Sum `changed=N` across every host in the PLAY RECAP. Per-host, because "some host changed"
# is the question, and a recap with ten hosts and one change is not idempotent.
changed_total() { # recap-file
  awk '
    /changed=[0-9]+/ {
      if (match($0, /changed=[0-9]+/)) {
        total += substr($0, RSTART + 8, RLENGTH - 8)
      }
    }
    END { print total + 0 }
  ' "$1"
}

changed_hosts() { # recap-file
  awk '
    match($0, /changed=[0-9]+/) {
      n = substr($0, RSTART + 8, RLENGTH - 8) + 0
      if (n > 0) { printf "%s ", $1 }
    }
  ' "$1"
}

run_playbook() { # log-file  [extra flags...]
  local log="$1"; shift
  local code=0
  printf '::group::ansible-playbook %s%s\n' "$PLAYBOOK" "$*"
  # `pipefail` is set, so `| tee` cannot report tee's exit code in place of ansible's — the
  # failure this repository exists to stop repeating.
  "$ANSIBLE_PLAYBOOK_BIN" "${base_args[@]}" ${extra[@]+"${extra[@]}"} "$@" "$PLAYBOOK" \
    2>&1 | tee "$log" || code=$?
  printf '::endgroup::\n'
  return $code
}

run_log="${work}/run.log"
run_args=()
$check_mode && run_args+=( --check )

code=0
run_playbook "$run_log" ${run_args[@]+"${run_args[@]}"} || code=$?
changed="$(changed_total "$run_log")"

if (( code != 0 )); then
  tremvok::set_output deployed false
  tremvok::set_output changed-tasks "$changed"
  tremvok::set_output idempotent false
  tremvok::summary "## Ansible — failed"
  tremvok::summary ""
  tremvok::summary "\`${PLAYBOOK}\` exited ${code}. The run log has the output."
  tremvok::fail "ansible-playbook exited ${code}"
fi

tremvok::log "run complete: ${changed} changed task(s)"

# ── prove it converged ───────────────────────────────────────────────────────────────────
idempotent=""
if $check_mode; then
  tremvok::log "check mode, so nothing was applied and there is nothing to verify"
elif ! tremvok::is_true "$VERIFY_IDEMPOTENCE"; then
  tremvok::log "ansible-verify-idempotence is off; not proving convergence"
else
  verify_log="${work}/verify.log"
  code=0
  run_playbook "$verify_log" --check || code=$?
  if (( code != 0 )); then
    # A playbook that errors in check mode is a defect in the playbook, not in the fleet —
    # a task without check-mode support, usually. Say which, rather than "verification
    # failed", because the fix is in different hands.
    tremvok::set_output deployed true
    tremvok::set_output changed-tasks "$changed"
    tremvok::set_output idempotent false
    tremvok::fail "the playbook applied cleanly but could not be re-run in check mode (exit ${code}). Usually a task with no check-mode support; give it \`check_mode: false\` or set ansible-verify-idempotence: false."
  fi
  still_changing="$(changed_total "$verify_log")"
  if (( still_changing > 0 )); then
    tremvok::set_output deployed true
    tremvok::set_output changed-tasks "$changed"
    tremvok::set_output idempotent false
    tremvok::summary "## Ansible — not idempotent"
    tremvok::summary ""
    tremvok::summary "A second check-mode run still reports ${still_changing} changed task(s) on: $(changed_hosts "$verify_log")"
    tremvok::fail "the playbook is not idempotent: a second check-mode run still wants to change ${still_changing} task(s) on $(changed_hosts "$verify_log"). A zero exit only proves it ran."
  fi
  idempotent=true
  tremvok::log "idempotent: a second check-mode run found nothing left to change"
fi

tremvok::set_output deployed "$($check_mode && printf false || printf true)"
tremvok::set_output changed-tasks "$changed"
tremvok::set_output idempotent "${idempotent:-}"

tremvok::summary "## Ansible — $($check_mode && printf 'checked' || printf 'applied')"
tremvok::summary ""
tremvok::summary "| | |"
tremvok::summary "|:--|:--|"
tremvok::summary "| Playbook | \`${PLAYBOOK}\` |"
tremvok::summary "| Inventory | \`${INVENTORY}\` |"
[[ -n "$LIMIT" ]] && tremvok::summary "| Limit | \`${LIMIT}\` |"
[[ -n "$TAGS" ]] && tremvok::summary "| Tags | \`${TAGS}\` |"
tremvok::summary "| Changed tasks | ${changed} |"
tremvok::summary "| Idempotent | \`${idempotent:-not checked}\` |"
exit 0
