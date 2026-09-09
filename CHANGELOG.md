# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed — BREAKING (v2)

- **The `docs` target is now `github-pages`,** and its inputs are prefixed `pages-` rather
  than `docs-` (`docs-toolchain` → `pages-toolchain`, and so on). The target is named for
  where it publishes, like every other target.
- **`docs-target` is removed.** Once the target *is* `github-pages` its only other value was
  `none`, and GitHub Pages has no preview destination: there is one site, and publishing to
  it is publishing. A pull request (`mode: preview`) or a `dry-run` now builds and checks
  without staging an artifact, which is what those already mean everywhere else.

- **One action, five targets.** `target` is now the deployment target
  (`docs` · `s3-cloudfront` · `lambda-zip` · `terragrunt` · `ansible`) and is the only
  required input. At v1 `target` meant the docs destination; that is now `docs-target`, and
  every other docs input gained a `docs-` prefix. Full table in
  [docs/migration.md](docs/migration.md). **`@v1` is unchanged and keeps working.**
- **The `deploy/` entry point is gone.** `MagmaMoose/tremvok/deploy@v1` no longer exists; its
  three targets are targets on the root action, with `aws-`, `s3-`, `cloudfront-` and
  `lambda-` prefixes on its inputs. Its scripts moved from `deploy/scripts/` to `scripts/`.
- **The reusable workflows are gone.** `.github/workflows/docs.yml` and
  `docs-github-pages.yml` are removed: one action is the whole product, and a second callable
  surface for one target was a place for the two to disagree. The Pages deploy job they
  carried is ten lines in the caller's own workflow — `examples/docs.yml`.
- **An inapplicable input now fails the run.** `validate-inputs.sh` checks every input
  against the selected target before the checkout and reports every mistake at once. At v1
  an undeclared input was a warning nothing acted on.
- **A plan-only Terragrunt run reports success**, not failure. It deployed nothing on
  purpose; the notification used to call that a failed deploy.
- `mode: auto` now resolves `schedule` and `pull_request_review`, which it used to refuse —
  breaking the Terragrunt drift run on its own cron.

### Added

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

[Unreleased]: https://github.com/MagmaMoose/tremvok/commits/main
