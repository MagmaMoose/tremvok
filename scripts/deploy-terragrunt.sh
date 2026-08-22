#!/usr/bin/env bash
# The Terragrunt target: discover -> plan -> gate on an approval -> apply.
#
# This is the Atlantis replacement. It exists for one reason that has nothing to do with
# features: Atlantis runs in the cluster and needs a **stored** AWS credential able to create
# IAM roles and policies — which means whatever it can assume, it can also grant itself. The
# same work in GitHub Actions authenticates by OIDC: a role assumed per run, nothing at rest.
# Deleting that credential is a stronger argument than any convenience.
#
# The flow:
#   pull_request           plan every affected stack, comment the result, publish the check
#                          as `action_required` when there is anything to apply
#   review (approved)      apply the pull request's merge result, then turn the check green
#   push to the default    apply what was merged
#   schedule               plan everything (drift), notify on changes or failures
#
# What is deliberately NOT here: applying an unapproved change. An approval is the
# authorisation, and a merge that never had one is *reported* rather than applied — an
# unapproved merge is a branch-protection problem, and turning the default branch red does not
# fix it while leaving the stacks unapplied and invisible would.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${here}/lib/common.sh"

ROOT_DIR="${ROOT_DIR:-terraform}"
SCOPE="${SCOPE:-auto}"                 # auto | all | changed
CHANGED_FILES="${CHANGED_FILES:-}"     # a file listing changed paths
EVENT_NAME="${EVENT_NAME:-}"
PR_NUMBER="${PR_NUMBER:-}"
HEAD_SHA="${HEAD_SHA:-}"
APPLY="${APPLY:-auto}"                 # auto | never | force
CHECK_NAME="${CHECK_NAME:-Terragrunt apply}"
RUN_URL="${RUN_URL:-}"
WORK_DIR="${WORK_DIR:-${RUNNER_TEMP:-/tmp}/tremvok-terragrunt}"
DRY_RUN="${DRY_RUN:-false}"
MAX_COMMENT_EXCERPT="${MAX_COMMENT_EXCERPT:-6000}"

mkdir -p "$WORK_DIR"

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '-' | sed -E 's/-+/-/g; s/-$//'; }

# `sed 's/^./\U&/'` is a GNU extension that BSD sed (macOS) silently does not apply, so the
# first character is upper-cased by hand.
capitalize() {
  printf '%s%s' "$(printf '%s' "${1:0:1}" | tr '[:lower:]' '[:upper:]')" "${1:1}"
}

# ── which stacks ─────────────────────────────────────────────────────────────────────────
scope="$SCOPE"
if [[ "$scope" == "auto" ]]; then
  case "$EVENT_NAME" in
    schedule|workflow_dispatch) scope="all" ;;
    *) scope="changed" ;;
  esac
fi

# `while read` rather than `mapfile`, which is bash 4 — see the note in lib/common.sh. The
# loop also drops blank lines, which mapfile would have kept as empty array elements.
stacks=()
discover_output=""
if [[ "$scope" == "all" ]]; then
  discover_output="$(ROOT_DIR="$ROOT_DIR" "${here}/terragrunt-discover.sh" all)"
else
  [[ -n "$CHANGED_FILES" && -f "$CHANGED_FILES" ]] \
    || tremvok::fail "scope=changed needs changed-files to point at a file listing the changed paths"
  discover_output="$(ROOT_DIR="$ROOT_DIR" "${here}/terragrunt-discover.sh" changed "$CHANGED_FILES")"
fi
while IFS= read -r stack; do
  [[ -n "$stack" ]] && stacks+=("$stack")
done <<<"$discover_output"

tremvok::log "discovered ${#stacks[@]} stack(s) (scope=${scope})"

if (( ${#stacks[@]} == 0 )); then
  tremvok::summary "## Terragrunt — nothing affected"
  tremvok::summary ""
  tremvok::summary "The changed files map to no automated stack, so there is nothing to plan or apply."
  # The check still reports. A required check that stays silent blocks the pull request
  # forever, and "this change touches no Terraform" is a perfectly good success.
  CHECK_NAME="$CHECK_NAME" HEAD_SHA="$HEAD_SHA" CONCLUSION=success \
    TITLE="No Terraform stacks affected" DETAILS_URL="$RUN_URL" \
    SUMMARY="This change maps to no automated stack, so there is nothing to apply." \
    "${here}/publish-check.sh"
  tremvok::set_output stacks 0
  tremvok::set_output plan-changes 0
  tremvok::set_output applied false
  tremvok::set_output deployed true
  exit 0
fi

# ── plan every stack, continuing past failures ───────────────────────────────────────────
plan_failures=0
plan_changes=0
rows=""
details=""

for stack in "${stacks[@]}"; do
  out="${WORK_DIR}/plan/$(sanitize "$stack")"
  mkdir -p "$out"
  printf '::group::plan %s\n' "$stack"
  if tremvok::is_true "$DRY_RUN"; then
    printf 'no-changes\n' >"${out}/status"
    printf 'DRY RUN: terragrunt plan in %s\n' "$stack" >"${out}/plan.txt"
  else
    # Deliberately not `|| true`: the status file is the result, and the exit code is only
    # used to decide whether to print the tail of the log.
    set +e
    "${here}/terragrunt-run.sh" plan "$stack" "$out"
    code=$?
    set -e
  fi
  status="failed"
  [[ -f "${out}/status" ]] && status="$(<"${out}/status")"
  [[ "$status" == "failed" ]] && plan_failures=$(( plan_failures + 1 ))
  [[ "$status" == "changes" ]] && plan_changes=$(( plan_changes + 1 ))
  tremvok::log "PLAN ${stack} -> ${status}"
  if [[ "$status" == "failed" ]]; then
    for log in plan.txt init.txt; do
      [[ -s "${out}/${log}" ]] || continue
      printf -- '--- %s (tail) ---\n' "$log"
      "${here}/terragrunt-run.sh" redact "${out}/${log}" | tail -n 40
    done
  fi
  printf '::endgroup::\n'

  case "$status" in
    no-changes) badge='✅ no changes' ;;
    changes) badge='📝 changes' ;;
    *) badge='❌ failed' ;;
  esac
  summary_line="$(grep -aoE 'Plan: [0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy' "${out}/plan.txt" 2>/dev/null | tail -1 || true)"
  [[ -z "$summary_line" ]] && summary_line=$([[ "$status" == "no-changes" ]] && printf 'No changes' || printf 'see details')
  short="${stack#"${ROOT_DIR}"/}"
  rows+="| \`${short}\` | ${badge} | ${summary_line} |"$'\n'

  if [[ -s "${out}/plan.txt" ]]; then
    excerpt="$("${here}/terragrunt-run.sh" redact "${out}/plan.txt" | tail -c "$MAX_COMMENT_EXCERPT")"
  else
    excerpt='No plan output was produced; see the workflow run.'
  fi
  # Single quotes here are the printf format string; %s args expand as positional parameters
  # shellcheck disable=SC2016
  details+="$(printf '<details><summary><code>%s</code> — %s</summary>\n\n```text\n%s\n```\n</details>' "$short" "$status" "$excerpt")"$'\n'
done

tremvok::summary "## Terragrunt plan"
tremvok::summary ""
tremvok::summary "| Stack | Result | Plan |"
tremvok::summary "|:--|:--|:--|"
tremvok::summary "$rows"

# ── decide whether this run may apply ────────────────────────────────────────────────────
approver_list=""
approval_readable=true
if [[ -n "$PR_NUMBER" ]]; then
  # Captured to a variable first: `if ! x="$(cmd)"` keeps the command's exit status, which is
  # the whole point here. An unreadable review list must never look like "nobody approved" —
  # but it must not fail a run that was only ever going to plan either, so it is recorded and
  # enforced at the apply decision below.
  if approvers_raw="$(PR_NUMBER="$PR_NUMBER" "${here}/approval-gate.sh" 2>/dev/null)"; then
    while IFS= read -r who; do
      [[ -n "$who" ]] && approver_list="${approver_list}@${who} "
    done <<<"$approvers_raw"
  else
    approval_readable=false
  fi
fi
approver_list="${approver_list% }"

may_apply=false
apply_reason=""
case "$APPLY" in
  never)
    apply_reason="apply is disabled for this run"
    ;;
  force)
    may_apply=true
    apply_reason="apply was requested explicitly"
    ;;
  auto|*)
    if [[ -n "$approver_list" ]]; then
      may_apply=true
      apply_reason="approved by ${approver_list}"
    elif [[ "$approval_readable" == false ]]; then
      apply_reason="the review list could not be read, so this run refuses to apply"
    else
      apply_reason="waiting for an independent approval"
    fi
    ;;
esac

if (( plan_failures > 0 )) && [[ "$may_apply" == true ]]; then
  may_apply=false
  apply_reason="${plan_failures} stack(s) failed to plan"
fi

# ── the pull-request comment ─────────────────────────────────────────────────────────────
gate_section=""
if [[ -n "$PR_NUMBER" ]]; then
  if [[ "$may_apply" == true ]]; then
    gate_section=$(printf '### Apply\n\n⏳ **%s — applying now.**\n\nThis section is rewritten when the run finishes.\n' "$apply_reason")
  elif (( plan_changes == 0 && plan_failures == 0 )); then
    gate_section=$(printf '### Apply\n\n✅ **Nothing to apply.** Every affected stack planned clean.\n')
  else
    gate_section=$(printf '### Apply\n\n🔒 **%s.**\n\nApproving this pull request applies the stacks above — the run picks up the merge result, exactly what lands on the default branch — and the merge unblocks once it passes.\n' "$(capitalize "$apply_reason")")
  fi
fi

# `if` blocks, not `[[ ... ]] && printf`. The last command inside a command substitution sets
# the substitution's exit status, so a false `[[ ]]` at the end makes the *assignment* fail —
# and under `set -e` that kills the run. It only bites when the optional line is absent, which
# here means: every push event, right after a successful plan.
comment_body="$(
  printf '## Terragrunt plan\n\n'
  printf '| Stack | Result | Plan |\n|:--|:--|:--|\n%s\n' "$rows"
  printf '%s\n' "$details"
  if [[ -n "$RUN_URL" ]]; then
    printf '\n_[Full output in the workflow run](%s); credential-shaped values are redacted._\n' "$RUN_URL"
  fi
  if [[ -n "$gate_section" ]]; then
    printf '\n%s\n' "$gate_section"
  fi
)"
printf '%s' "$comment_body" >"${WORK_DIR}/comment.md"

if [[ -n "$PR_NUMBER" ]]; then
  PR_NUMBER="$PR_NUMBER" COMMENT_KEY="terragrunt" BODY_FILE="${WORK_DIR}/comment.md" \
    "${here}/notify-pr.sh" || tremvok::warn "the plan comment did not post."
fi

# ── apply ────────────────────────────────────────────────────────────────────────────────
applied=false
apply_failures=0
failed_stacks=()

if [[ "$may_apply" == true ]]; then
  applied=true
  for stack in "${stacks[@]}"; do
    out="${WORK_DIR}/apply/$(sanitize "$stack")"
    mkdir -p "$out"
    printf '::group::apply %s\n' "$stack"
    if tremvok::is_true "$DRY_RUN"; then
      printf 'applied\n' >"${out}/status"
    else
      set +e
      "${here}/terragrunt-run.sh" apply "$stack" "$out"
      code=$?
      set -e
      if (( code != 0 )); then
        apply_failures=$(( apply_failures + 1 ))
        failed_stacks+=("${stack#"${ROOT_DIR}"/}")
        # The run buffers every invocation to a file, so without this a failed apply leaves an
        # empty log group and the reason nowhere at all.
        for log in apply.txt init.txt; do
          [[ -s "${out}/${log}" ]] || continue
          printf -- '--- %s (tail) ---\n' "$log"
          "${here}/terragrunt-run.sh" redact "${out}/${log}" | tail -n 40
        done
      fi
    fi
    printf '::endgroup::\n'
  done
fi

# ── report ───────────────────────────────────────────────────────────────────────────────
if (( plan_failures > 0 )); then
  conclusion="failure"
  title="${plan_failures} stack(s) failed to plan"
  summary="Fix the plan before applying. The plan comment on this pull request has the redacted output."
elif [[ "$applied" == true && $apply_failures -gt 0 ]]; then
  conclusion="failure"
  title="${apply_failures} of ${#stacks[@]} stack(s) failed to apply"
  summary="Failed: ${failed_stacks[*]}. The run log has the redacted output for each."
elif [[ "$applied" == true ]]; then
  conclusion="success"
  title="Applied"
  summary="${#stacks[@]} stack(s) applied — ${apply_reason}. Safe to merge."
elif (( plan_changes == 0 )); then
  conclusion="success"
  title="No changes to apply"
  summary="Every affected stack planned clean, so there is nothing to apply."
else
  # Not a failure and not a success: there is real work outstanding and a human has to
  # authorise it. `action_required` is the only conclusion that says so and still blocks.
  conclusion="action_required"
  title="Apply required before merge"
  summary="${plan_changes} stack(s) have pending changes — ${apply_reason}. This check turns green once they are applied."
fi

CHECK_NAME="$CHECK_NAME" HEAD_SHA="$HEAD_SHA" CONCLUSION="$conclusion" TITLE="$title" \
  SUMMARY="$summary" DETAILS_URL="$RUN_URL" "${here}/publish-check.sh"

tremvok::set_output stacks "${#stacks[@]}"
tremvok::set_output plan-changes "$plan_changes"
tremvok::set_output plan-failures "$plan_failures"
tremvok::set_output applied "$applied"
tremvok::set_output apply-failures "$apply_failures"
tremvok::set_output deployed "$applied"
tremvok::set_output approvers "$approver_list"

(( plan_failures == 0 )) || tremvok::fail "${plan_failures} stack(s) failed to plan."
(( apply_failures == 0 )) || tremvok::fail "${apply_failures} of ${#stacks[@]} stack(s) failed to apply: ${failed_stacks[*]}"
