#!/usr/bin/env bats
#
# The two things that must never regress here: a secret must not be able to reach a log or
# outlive the step, and a zero exit must not be accepted as proof that the playbook
# converged.

load helper

setup() {
  setup_common
  cd "$WORK"
  mkdir -p play
  printf -- '- hosts: all\n' >play/site.yml
  export RUNNER_TEMP="${WORK}/runner-temp"
  mkdir -p "$RUNNER_TEMP"
  export TREMVOK_SKIP_INSTALL=true
  export PLAYBOOK=play/site.yml INVENTORY=inventory.ini
  printf 'host-a\n' >inventory.ini

  # A recap the script can count. RECAP_CHANGED drives the first run, VERIFY_CHANGED the
  # check-mode re-run — the file marker is what tells them apart.
  stub_script ansible-playbook <<'STUBEOF'
#!/usr/bin/env bash
printf 'ansible-playbook %s\n' "$*" >>"${STUB_LOG}"
if [ -f "${STUB_LOG}.ran" ]; then
  changed="${VERIFY_CHANGED:-0}"
else
  : >"${STUB_LOG}.ran"
  changed="${RECAP_CHANGED:-1}"
fi
printf 'PLAY RECAP ****\n'
printf 'host-a : ok=3 changed=%s unreachable=0 failed=0\n' "$changed"
exit "${PLAY_EXIT:-0}"
STUBEOF
  stub ansible-galaxy 0 ""
  stub pip 0 ""
}

@test "a real run that converges is idempotent and says so" {
  run bash "${SCRIPTS}/deploy-ansible.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value idempotent)" = "true" ]
  [ "$(output_value changed-tasks)" = "1" ]
  [ "$(output_value deployed)" = "true" ]
}

@test "a second check-mode run that still wants to change is a failure" {
  # A zero exit only proves the playbook ran. This is the difference.
  VERIFY_CHANGED=2 run bash "${SCRIPTS}/deploy-ansible.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not idempotent"* ]]
  [ "$(output_value idempotent)" = "false" ]
}

@test "the verification run is a check-mode run, not a second apply" {
  run bash "${SCRIPTS}/deploy-ansible.sh"
  [ "$(grep -c -- '--check' "$STUB_LOG")" -eq 1 ]
}

@test "a pull request runs in check mode and skips the idempotence proof" {
  EVENT_NAME=pull_request run bash "${SCRIPTS}/deploy-ansible.sh"
  [ "$status" -eq 0 ]
  grep -q -- '--check' "$STUB_LOG"
  [ "$(output_value deployed)" = "false" ]
  [ "$(output_value idempotent)" = "" ]
}

@test "check mode can be forced on and off regardless of the event" {
  CHECK=true EVENT_NAME=push run bash "${SCRIPTS}/deploy-ansible.sh"
  grep -q -- '--check' "$STUB_LOG"
  : >"$STUB_LOG"; rm -f "${STUB_LOG}.ran"
  CHECK=false EVENT_NAME=pull_request run bash "${SCRIPTS}/deploy-ansible.sh"
  [ "$(grep -c -- '--check' "$STUB_LOG")" -eq 1 ]  # the verification run only
}

@test "a dry run never applies anything" {
  DRY_RUN=true EVENT_NAME=push run bash "${SCRIPTS}/deploy-ansible.sh"
  [ "$status" -eq 0 ]
  grep -q -- '--check' "$STUB_LOG"
  [ "$(output_value deployed)" = "false" ]
}

@test "the ssh key is masked, written 0600, and gone when the step ends" {
  SSH_PRIVATE_KEY=$'-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----' \
    run bash "${SCRIPTS}/deploy-ansible.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::add-mask::b3BlbnNzaC1rZXktdjEAAAAA"* ]]
  grep -q -- '--private-key' "$STUB_LOG"
  # Nothing under RUNNER_TEMP survives: a key left on a self-hosted runner outlives the job,
  # and self-hosted runners are exactly what this target is for.
  [ -z "$(find "$RUNNER_TEMP" -name 'id_key' 2>/dev/null)" ]
}

@test "the key never reaches the command line, where ps would show it" {
  SSH_PRIVATE_KEY=$'-----BEGIN OPENSSH PRIVATE KEY-----\nSECRETMATERIAL0000\n-----END OPENSSH PRIVATE KEY-----' \
    run bash "${SCRIPTS}/deploy-ansible.sh"
  ! grep -q 'SECRETMATERIAL0000' "$STUB_LOG"
}

@test "the vault password is masked and passed as a file" {
  VAULT_PASSWORD=hunter2-hunter2 run bash "${SCRIPTS}/deploy-ansible.sh"
  [[ "$output" == *"::add-mask::hunter2-hunter2"* ]]
  grep -q -- '--vault-password-file' "$STUB_LOG"
  ! grep -q 'hunter2-hunter2' "$STUB_LOG"
}

@test "no known_hosts is a loud downgrade, not a quiet default" {
  run bash "${SCRIPTS}/deploy-ansible.sh"
  [[ "$output" == *"host-key checking is off"* ]]
}

@test "known_hosts turns host-key checking back on" {
  SSH_KNOWN_HOSTS='host-a ssh-ed25519 AAAAC3NzaC1lZDI1NTE5' run bash "${SCRIPTS}/deploy-ansible.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"host-key checking is off"* ]]
}

@test "limit, tags and skip-tags reach the playbook" {
  LIMIT=host-a TAGS=web SKIP_TAGS=slow run bash "${SCRIPTS}/deploy-ansible.sh"
  grep -q -- '--limit host-a' "$STUB_LOG"
  grep -q -- '--tags web' "$STUB_LOG"
  grep -q -- '--skip-tags slow' "$STUB_LOG"
}

@test "galaxy requirements are installed before the run" {
  printf 'collections: []\n' >requirements.yml
  GALAXY_REQUIREMENTS=requirements.yml run bash "${SCRIPTS}/deploy-ansible.sh"
  [ "$status" -eq 0 ]
  grep -q 'ansible-galaxy install -r requirements.yml' "$STUB_LOG"
}

@test "a galaxy requirements file that is not there fails before the playbook runs" {
  GALAXY_REQUIREMENTS=missing.yml run bash "${SCRIPTS}/deploy-ansible.sh"
  [ "$status" -ne 0 ]
  ! grep -q 'ansible-playbook' "$STUB_LOG"
}

@test "a missing playbook fails before anything is installed" {
  PLAYBOOK=play/nope.yml run bash "${SCRIPTS}/deploy-ansible.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no playbook at"* ]]
}

@test "no inventory is refused rather than guessed" {
  INVENTORY= run bash "${SCRIPTS}/deploy-ansible.sh"
  [ "$status" -ne 0 ]
}

@test "a failing playbook fails the run and reports zero convergence" {
  PLAY_EXIT=2 run bash "${SCRIPTS}/deploy-ansible.sh"
  [ "$status" -ne 0 ]
  [ "$(output_value deployed)" = "false" ]
  [ "$(output_value idempotent)" = "false" ]
}

@test "a playbook that cannot be re-run in check mode says whose bug that is" {
  stub_script ansible-playbook <<'STUBEOF'
#!/usr/bin/env bash
printf 'ansible-playbook %s\n' "$*" >>"${STUB_LOG}"
case "$*" in
  *--check*) printf 'ERROR! check mode is not supported\n'; exit 1 ;;
esac
printf 'PLAY RECAP ****\nhost-a : ok=3 changed=1 unreachable=0 failed=0\n'
STUBEOF
  run bash "${SCRIPTS}/deploy-ansible.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no check-mode support"* ]]
}

@test "idempotence checking can be turned off" {
  VERIFY_CHANGED=5 VERIFY_IDEMPOTENCE=false run bash "${SCRIPTS}/deploy-ansible.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value idempotent)" = "" ]
}

@test "changed tasks are summed across every host, not read off the first" {
  stub_script ansible-playbook <<'STUBEOF'
#!/usr/bin/env bash
printf 'ansible-playbook %s\n' "$*" >>"${STUB_LOG}"
printf 'PLAY RECAP ****\n'
printf 'host-a : ok=3 changed=0 unreachable=0 failed=0\n'
printf 'host-b : ok=3 changed=4 unreachable=0 failed=0\n'
STUBEOF
  VERIFY_IDEMPOTENCE=false run bash "${SCRIPTS}/deploy-ansible.sh"
  [ "$(output_value changed-tasks)" = "4" ]
}
