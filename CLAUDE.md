# Tremvok

Deployment orchestration + notifications: the deploy-side counterpart to Diatreme. Two surfaces
in one repo — a GitHub **composite action** (`action.yml` + `scripts/*.sh`, bash, bats-tested)
targeting AWS, and a **FastAPI deployment-record/notifier service** (`src/tremvok/`, Python 3.12,
uv, pytest) that runs as a Lambda. They talk over HTTP; neither imports the other. Most users
only touch the action. Infrastructure is `terraform/`, provable end to end on LocalStack.

@.claude/QUICK_START.md
@.claude/ARCHITECTURE_MAP.md
@.claude/COMMON_MISTAKES.md

## Hard constraints

- **No Cloudflare.** Every target and every hosted component is AWS, inside the always-free
  allowances. New spend needs an explicit decision, not a default.
- **Bash 3.2.** GitHub's macOS runners ship it. No `${x,,}`, `${x^}`, `mapfile`, `declare -A`.
  `tests/bats/portability.bats` enforces this.
- **Secrets are SSM `SecureString`.** Never Lambda environment variables, never Terraform
  resources.
- **Notification sinks are failure-isolated.** A deploy that succeeded never fails because a
  webhook did.

## Finding code

- `AGENTS.md` = full editing rules and local validation commands. `README.md` = the user guide.
  `terraform/README.md` = costs, the cost ceiling and the LocalStack gaps.
- Load `.claude/decisions/` (ADRs) and `.claude/sessions/` ONLY when the task relates to them.
- Human docs are `./docs` (MkDocs); `.claude/*.md` is terse agent context. Keep them distinct.

## [tooling]

- Prefer targeted line-range reads over whole files. `action.yml` is long; read the input block
  you need, not the file.
- grep/find/glob: return matching paths and matched lines only.
- Commands that can flood output (test runs, terraform plans): pipe through `head`/`tail`/`grep`
  or redirect to `.claude/last_output.txt` and read ranges.
- After a successful write/edit, trust it; don't re-read to "verify".

## [maintenance]

- Bug that took >1h: append to `.claude/COMMON_MISTAKES.md`.
- Architectural decision: run `/adr`.
- Public behaviour/API/config/setup changed: run `/update-docs`.
- Keep this file under ~500 tokens; push detail into on-demand `.claude/` files.
