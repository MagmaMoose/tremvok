# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.0.0]

Released as v1.0.26 and retagged: the breaking changes below are v2, and were only ever
called v1.x because the release pipeline could not see them.

### Fixed — the floating major tag

- **`v1` no longer floats onto a breaking release.** `GitVersion.yml` teaches GitVersion
  to read Conventional Commits, so a `feat!:` subject or a `BREAKING CHANGE:` footer bumps
  the major and `feat:` bumps the minor. Until now GitVersion ran on its built-in defaults,
  which only understand `+semver:` tokens: every release since v1.0.0 was a patch,
  including the two that deleted the reusable workflows and renamed every docs input. The
  release job then force-moved `v1` onto them, and nine repositories pinned to `@v1` were
  handed the v2 contract without a version change to warn them.

### Changed — BREAKING (v2)

- **The `docs` target is now `github-pages`,** and its inputs are prefixed `pages-` rather
  than `docs-` (`docs-toolchain` → `pages-toolchain`, and so on). The target is named for
  where it publishes, like every other target.
- **`docs-target` is removed.** Once the target *is* `github-pages` its only other value was
  `none`, and GitHub Pages has no preview destination: there is one site, and publishing to
  it is publishing. A pull request (`mode: preview`) or a `dry-run` now builds and checks
  without staging an artifact, which is what those already mean everywhere else.

- **One action, six targets.** `target` is now the deployment target
  (`github-pages` · `s3-cloudfront` · `lambda-zip` · `terragrunt` · `ansible` ·
  `cloudflare-workers`) and is the only required input. At v1 `target` meant the docs
  destination. Full table in [docs/migration.md](docs/migration.md). **`@v1` is frozen at
  v1.0.18 and keeps working** — it was briefly not, see *Fixed* below.
- **The `deploy/` entry point is gone.** `MagmaMoose/tremvok/deploy@v1` no longer exists; its
  three targets are targets on the root action, with `aws-`, `s3-`, `cloudfront-` and
  `lambda-` prefixes on its inputs. Its scripts moved from `deploy/scripts/` to `scripts/`.
- **The reusable workflows are gone.** `.github/workflows/docs.yml` and
  `docs-github-pages.yml` are removed: one action is the whole product, and a second callable
  surface for one target was a place for the two to disagree. The Pages deploy job they
  carried is ten lines in the caller's own workflow — `examples/github-pages.yml`.
- **An inapplicable input now fails the run.** `validate-inputs.sh` checks every input
  against the selected target before the checkout and reports every mistake at once. At v1
  an undeclared input was a warning nothing acted on.
- **A plan-only Terragrunt run reports success**, not failure. It deployed nothing on
  purpose; the notification used to call that a failed deploy.
- `mode: auto` now resolves `schedule` and `pull_request_review`, which it used to refuse —
  breaking the Terragrunt drift run on its own cron.

### Added

- **`terragrunt-apply-on-merge`** (default `false`): a push to the default branch can now
  apply what was merged. **The default is unchanged for existing callers.** With it off, which
  is what you get on upgrade, a push plans exactly as it always has: no commit-to-pull-request
  lookup, no approval read, nothing applied. Turning it on is the decision to let a merge
  apply.

  A push event carries no pull request, and the approval that authorises the apply belongs to
  the pull request the commit was merged from, so with this on the run resolves it from the
  commit (`scripts/resolve-merged-pr.sh`, `GET /repos/{repo}/commits/{sha}/pulls`) and feeds it
  to the existing approval gate. Which pull request wins is stated rather than inherited from
  the API's ordering: one whose `base.ref` is the pushed branch, else the oldest `merged_at`.
  Three outcomes stay distinct: merged with an independent approval applies; merged without
  one, or pushed directly, plans and reports with a `neutral` check run rather than failing,
  because an unapproved merge is a branch-protection matter; and an API that cannot be read
  fails the run *after* the check run and the step outputs are published, because an outage
  must never read as "nobody approved" and a required check that never reports blocks a pull
  request for ever. (Not after the plan comment: an unreadable lookup is the case where there
  is no thread to comment on, which is why the failure is reported on the check run.) Neither
  refusal fires on a merge whose stacks all plan clean — an unreadable review list and an
  unreadable lookup are guarded the same way, because refusing to apply nothing is not a
  refusal and a transient API blip should not turn the default branch red while the same run
  reports "No changes to apply". Both still warn, so a token missing `pull-requests: read`
  is visible rather than silent. The plan comment on the merged pull request is rewritten
  in place to the apply result instead of being left on "applying now".

  It is a separate input from `terragrunt-apply` on purpose: that one answers "who may
  authorise an apply?", this one answers "should a merge commit apply at all?". The path needs
  `pull-requests: read`, which the `pull-requests: write` the docs already ask for covers.

- **With `terragrunt-apply-on-merge` on**, a run with pending changes and no open pull request
  (a merge, a direct push, or the scheduled drift run) publishes a `neutral` check run rather
  than `action_required`: that check lands on a commit already on the branch, where there is no
  merge left to block, and turning the default branch red is not what fixes an unapproved
  merge. **With the input off, which is the default, the conclusion is `action_required`
  exactly as before.** It is the better answer either way, but it is still a different
  conclusion from the one a caller sees today and somebody may be watching for it on a drift
  cron, so it arrives with the input rather than with the tag.

- **`terragrunt-preflight-urls`**: URLs probed once each, with an 8-second timeout, before the
  first plan. Terragrunt buffers plan output to a file, so a state backend or provider API the
  runner cannot reach is a silent wait until `terragrunt-timeout` rather than an error. Any
  HTTP answer passes, `401` and `403` included, because an unauthenticated probe of a
  credentialed endpoint is supposed to be refused; only a curl code of `000` fails, and a `5xx`
  warns and passes so a transient `503` cannot make this a flake. The runner's egress IP is
  printed on the failure path only. Empty (the default) probes nothing, so nothing changes for
  existing callers. This proves reachability, not authorisation. Nothing from this input is
  echoed raw: a refusal names the line by index and shows the URL with any userinfo replaced,
  because a guard that refuses a credential-bearing URL by printing the credential is worse
  than no guard.

- **`terragrunt-pull-request`**: act on a named pull request instead of the one in the event
  payload, for a manual run. One override drives all three consumers: the approval gate reads
  that pull request's reviews, the plan comment goes to its thread, and the check run is
  published against its head commit, fetched from the API because a dispatch event carries no
  pull request. Digits only, checked in the action's first step before the checkout, the tool
  install and the assume-role. A fork pull request is refused, as the automatic path already
  refuses fork code. `terragrunt-scope: auto` now means "the stacks that pull request touches"
  whenever a pull request is in scope, however it got there. Checking out
  `refs/pull/<n>/merge` stays the caller's `actions/checkout` config; the run warns, and never
  fails, when the tree does not contain the named head commit.

- **`ansible-vault-passthrough`** (default `false`): hand `VAULT_ADDR`, `VAULT_TOKEN` and
  `VAULT_NAMESPACE` to the `ansible-playbook` process, so a playbook can read its own secrets
  from the same HashiCorp Vault rather than having them copied into a second store that stops
  being rotated. Off by default, and the default now **removes** them from the playbook's
  environment: they were inherited by accident, and widening a credential's blast radius should
  be a decision. Needs both `vault-addr` and `vault-token`; with only one, nothing is passed and
  the run says so.

  The default has to be the one that unsets, and this was argued the other way. Defaulting to
  `true` would make the input a no-op with a name that claims otherwise, and the option to turn
  passthrough *off* would be the thing nobody knew to reach for. The `vault-*` inputs shipped
  one day before this, so the window in which anything can depend on the accidental inheritance
  is a day wide.

- **The playbook no longer inherits the SSH private key or the ansible-vault password
  either.** Same argument, applied to the rest of the credentials rather than a third of them:
  `SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS`, `VAULT_PASSWORD` and their `*_VAULT` partners reach the
  step as environment variables, and every child process inherits them, so a role or collection
  in the play could read the two most sensitive values this target handles. They are unset once
  their values are on disk at `0600`, which is what the `--private-key` and
  `--vault-password-file` flags point at, so the run itself needs nothing from the variables.
  There is no opt-out and no passthrough input for these: unlike a Vault token, they have no
  use inside a playbook that the file does not already serve.

- **Ansible secrets can be read from HashiCorp Vault.** `vault-addr` + `vault-token`, then
  name a secret by `<path>#<field>` with `ansible-ssh-private-key-vault`,
  `ansible-ssh-known-hosts-vault` or `ansible-vault-password-vault`. Copying a secret that
  already lives in Vault into a GitHub secret means rotating it in Vault silently stops
  rotating the copy; this removes the copy. Each `-vault` input is the alternative to its
  literal, never a supplement, and setting both fails. KV v1 and v2 both work without the
  caller declaring which. The value is masked and written to a `0600` file on the same single
  path a literal takes, and a failed read fails the run rather than proceeding with no key,
  which would surface as an SSH auth error a long way from the cause.

- **`terragrunt-stack-env`**: environment applied per stack, one `<glob> KEY=VALUE` per line,
  first match wins. For an estate whose production Terraform state lives in a separate
  storage account from the rest: one credential cannot reach both, so without this the only
  options are a job per credential class or a pipeline that fails on the first stack of the
  other kind. Values are passed with `env` rather than exported, so one stack's credential
  never reaches the next stack's run, and the apply gets the same environment the plan got.

- **`target: cloudflare-workers`** — deploy a Worker and its static assets with Wrangler.
  `mode: deploy` runs `wrangler deploy`; `mode: preview` runs
  `wrangler versions upload --preview-alias pr-<N>`, which uploads a version reachable on its
  own URL that takes **no production traffic**, so a pull request cannot land on the live
  routes. Supports assets-only Workers (no entry point, files served straight from the edge)
  and Workers that run code, via `cloudflare-main` and `cloudflare-build-command`. The
  Wrangler config stays authoritative for asset directory, routes, custom domains and 404
  handling; the inputs are overrides for what a workflow legitimately varies. Wrangler and
  Node versions are pinned, because the tool that publishes to production is not a floating
  dependency. Reverses the Cloudflare half of ADR 0001, see
  `.claude/decisions/0003-cloudflare-workers-target.md`.

- **`target: ansible`** — pinned Ansible and galaxy requirements, a playbook run over SSH,
  and an idempotence proof: after a real run the playbook runs again in check mode and the
  run fails if anything would still change. A zero exit only proves it ran. SSH keys and
  vault passwords are masked on receipt, written to `0600` files under `$RUNNER_TEMP`, never
  passed on a command line, and removed by a trap however the step exits. Check mode is the
  default on a pull request.
- **Terragrunt applies the saved plan.** `plan -out` writes it, `apply` applies that file, so
  what lands is the diff that was reviewed. A plan that has gone stale is re-planned with a
  warning rather than refused, and `PLAN SOURCE:` in the log names which one ran.
- **Pinned, checksum-verified tofu and terragrunt** (`terragrunt-bootstrap.sh`), cached per
  version pair on the runner, with a shared provider plugin cache. The binary that applies to
  production is no longer whatever the runner happened to have.
- Terragrunt gained `terragrunt-exclude`, `terragrunt-apply-operators` (who may force an
  apply; empty means nobody), `terragrunt-refresh` (skip the provider refresh on a pull
  request), `terragrunt-timeout` and `terragrunt-log-level`.
- **`scripts/lib/input-targets.json`**, generated from `action.yml` by
  `scripts/gen_input_targets.py`, is the single source for which inputs apply to which
  target — read by the runtime validator and by the generated reference, so the check and
  the documentation cannot disagree. CI fails on drift.
- `docs/migration.md`, and per-target permission blocks in the generated action reference.

### Fixed

- The three `examples/` workflows called `MagmaMoose/tremvok@v1` with AWS inputs the root
  action did not declare, so they built an MkDocs site instead of deploying. They now match
  the action they call — which is a large part of why the surfaces merged.
- `preflight.sh` no longer skips `docs` and `ansible` runs for want of an AWS credential
  neither target uses.
- `terragrunt-bootstrap.sh`'s checksum lookup runs with `|| true`: with `pipefail` on, a
  `grep` that matched nothing made the assignment non-zero and `set -e` exited the script
  silently, exactly where the loudest possible failure is wanted.
- **A malformed `terragrunt-stack-env` line no longer prints its VALUE.** The refusal
  interpolated the whole line into its `::error::` annotation, and that input exists to carry
  per-stack state-backend credentials, so a typo in a line holding a storage-account key
  published the key to a log as public as the repository. The message now names the line
  index, the glob and the KEY, and nothing at or after the first `=` — including when the glob
  itself was forgotten and the assignment landed in the glob slot.

### Added (previously unreleased, carried into v2)

- **Post-deploy verification** (`verify-url`, `verify-header`, `verify-header-match`) with
  retries, catching the deploy that uploaded but did not bind.
- **Notifications**: sticky pull-request comment, Slack and Microsoft Teams incoming webhooks,
  each optional and failure-isolated.
- **OIDC role assumption** (`assume-role.sh`), so no repository stores an AWS key.
- **Honest skips** for fork pull requests and repositories with no credential configured.
- **The Tremvok API** (`src/tremvok/`): FastAPI + Mangum on Lambda, recording deployment
  history in DynamoDB and fanning notifications out. Authenticated by GitHub Actions OIDC with
  a deny-by-default owner allowlist; the `repository` a record lands under is the token's claim.
- **RS256 verification with no crypto dependency** (`oidc.py`), keeping the Lambda package
  small and architecture-portable, with an optional pinned JWKS in Parameter Store for
  egress-restricted or Enterprise Server deployments.
- **Terraform module** (`terraform/modules/tremvok-api`) capped three independent ways —
  API Gateway throttle, Lambda reserved concurrency, provisioned DynamoDB — because AWS has no
  spend cap.
- **LocalStack harness** (`make -C terraform dev`) proving the whole stack without an AWS
  account.
- Tests: 188 `bats` cases over the shell scripts, 181 `pytest` cases over the API, the
  action contract and the applicability map, and an end-to-end smoke suite against LocalStack.

### Fixed

- **`lint-docs` classified a licence by pattern order, not by where it appears in the
  file.** A `LICENSE` opening "Proprietary License" that excepts one directory under
  Apache-2.0 was reported as Apache-2.0, so a correct README saying "Proprietary" failed
  with `claims Proprietary but LICENSE is Apache-2.0`. It took a consuming repository's
  docs site offline for three days over a licence claim that was right. The operative
  licence is now the one that appears FIRST in the file, since a licence states its own
  terms before its carve-outs.

[Unreleased]: https://github.com/MagmaMoose/tremvok/compare/v2.0.0...main
[2.0.0]: https://github.com/MagmaMoose/tremvok/releases/tag/v2.0.0
