# Tremvok

Deployment orchestration and notifications for MagmaMoose — the deploy-side counterpart to
[Diatreme](https://github.com/MagmaMoose/diatreme). Diatreme decides *what version, and whether
it is released*. Tremvok gets it **live**, proves it went live, and **tells the humans**.

Two surfaces in one repository, talking over HTTP and importing nothing from each other:

| | |
|---|---|
| **The action** — `action.yml` + `scripts/*.sh` | takes an already-built artifact, ships it to an AWS target, verifies it, announces it |
| **The API** — `src/tremvok/` (FastAPI on Lambda) | records every deployment and fans notifications out, authenticated by GitHub OIDC so no repository stores a credential |

Most users only need the action. The API is optional: leave `api-url` unset and nothing calls it.

```yaml
# .github/workflows/deploy.yml — the whole per-repo file
name: Deploy
on:
  push: { branches: [main] }
  pull_request:
  workflow_dispatch:

permissions:
  contents: read
  id-token: write          # assume the AWS role, and authenticate to the Tremvok API
  pull-requests: write     # the sticky preview comment

concurrency:
  group: deploy-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  deploy:
    runs-on: ${{ vars.SELFHOSTED_GITHUB_RUNNER || 'ubuntu-latest' }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: "24" }
      - run: npm ci && npm run build      # the build stays yours

      - uses: MagmaMoose/tremvok@v1
        with:
          target: s3-cloudfront
          artifact-path: dist
          aws-region: eu-west-1
          role-to-assume: ${{ vars.DEPLOY_ROLE_ARN }}
          bucket: ${{ vars.SITE_BUCKET }}
          distribution-id: ${{ vars.CLOUDFRONT_DISTRIBUTION }}
          site-url: https://magmamoose.com
          verify-url: https://magmamoose.com/
          verify-header: content-security-policy
          slack-webhook: ${{ secrets.SLACK_DEPLOY_WEBHOOK }}
```

---

## Why this exists

`deploy.yml` is the one pipeline file nobody owns. The [standard](https://github.com/MagmaMoose/standard)
Copier template owns files that must *exist* everywhere but differ per product; Caldrith
reconciles files that must be *identical* everywhere. Deployment fell between them, so every
product hand-rolled it — and the hand-rolled versions drifted into several implementations of
the same job, each having learned a different lesson the hard way:

> *"A deploy that uploads but does not bind is the failure worth catching: the old version keeps
> serving and everything looks green."*

> *"The first run **reported success** on an auth failure — precisely the outcome this file
> exists to prevent."* (`cmd | tee log` reports *tee's* exit code.)

Every guard in `scripts/` is one of those lessons, paid for once and now shared. See
[docs/architecture.md](docs/architecture.md) for the full list.

---

## Targets

### `s3-cloudfront` — a built static site

Syncs to S3 with per-class cache headers (fingerprinted assets immutable for a year, documents
revalidating), then invalidates CloudFront. Previews land under `previews/<alias>/`, so a pull
request can never touch a production object.

**It refuses to sync an empty artifact directory.** A build that quietly produced nothing,
followed by `aws s3 sync --delete`, empties the live site and exits `0` while doing it.

### `lambda-zip` — a Lambda package

Uploads to an **immutable** S3 key, updates the function, publishes a version, and moves an
alias. Three rules make it safe to automate:

* a key that already exists with different bytes is a hard failure, never an overwrite — that
  would change the code behind a version somebody already reviewed;
* a **preview publishes a version and stops**, so a pull request proves the package builds and
  deploys without changing what production serves;
* the deployed `CodeSha256` is compared against the local artifact, because "the API accepted
  my request" is not "the function runs my code".

### `terragrunt` — plan, gate on an approval, apply

The Atlantis replacement. Discovers affected stacks from the changed files, plans each one,
posts a rolling pull-request comment with a status table and redacted plan excerpts, and
publishes a `Terragrunt apply` check run that can be **required** — so a merge is blocked until
the stacks are actually applied. An independent approval is the apply authorisation.

Why replace Atlantis at all: it runs in the cluster and needs a **stored** AWS credential able
to create IAM roles and policies — whatever it can assume, it can also grant itself. The same
work in GitHub Actions authenticates by OIDC, a role assumed per run with nothing at rest.
Deleting that credential is a stronger argument than any feature.

---

## Inputs

| Input | Default | Purpose |
|---|---|---|
| `target` | *(required)* | `s3-cloudfront` · `lambda-zip` · `terragrunt` |
| `mode` | `auto` | `auto` \| `deploy` \| `preview` \| `rollback`. `auto`: push to the default branch = deploy, PR = preview, dispatch = deploy |
| `artifact-path` | `''` | The built artifact — a directory (`s3-cloudfront`) or a `.zip` (`lambda-zip`) |
| `environment` | `''` | Logical name in notifications and records. Defaults to `production` / `preview` |
| `working-directory` | `.` | Paths in other inputs are relative to it |
| `aws-region` | `''` | Falls back to `AWS_REGION` |
| `role-to-assume` | `''` | IAM role assumed with this run's OIDC token. Needs `id-token: write`. Empty ⇒ use credentials an earlier step configured |
| `role-duration-seconds` | `3600` | Assumed-role session lifetime |
| `bucket` | `''` | The site bucket (`s3-cloudfront`) or the artifact bucket (`lambda-zip`) |
| `key-prefix` | `''` | Prefix within the bucket |
| `distribution-id` | `''` | CloudFront distribution to invalidate. Empty ⇒ the CDN serves the old objects until its TTL expires |
| `site-url` | `''` | Base URL, used to build the URL in notifications |
| `delete-orphans` | `auto` | Pass `--delete` to the sync |
| `function-name` | `''` | `lambda-zip`: the function |
| `function-alias` | `live` | `lambda-zip`: the alias moved on a deploy |
| `version-label` | `''` | `lambda-zip`: names the immutable key. Defaults to the short SHA |
| `terraform-root` | `terraform` | `terragrunt`: where the stacks live |
| `terragrunt-scope` | `auto` | `auto` \| `all` \| `changed` |
| `terragrunt-apply` | `auto` | `auto` (apply on an independent approval) \| `never` \| `force` |
| `check-name` | `Terragrunt apply` | The check run published against the head commit |
| `verify-url` | `''` | Post-deploy: the URL that must answer. Empty skips verification |
| `verify-header` | `''` | Post-deploy: a response header that must be present |
| `verify-header-match` | `''` | Extended regex the header value must match |
| `verify-status` | `200` | Expected status |
| `verify-attempts` / `verify-delay` | `6` / `10` | Retry budget for propagation |
| `notify` | `always` | `always` \| `on-success` \| `on-failure` |
| `pr-comment` | `auto` | Sticky PR comment; `auto` = on for previews |
| `slack-webhook` / `teams-webhook` | `''` | Incoming-webhook URLs. Empty ⇒ sink off. Never fail the deploy |
| `api-url` | `''` | Tremvok API to record with. Empty ⇒ no record |
| `api-audience` | `tremvok` | OIDC audience the API expects |
| `auth-token` | `${{ github.token }}` | For the PR comment and the check run |
| `allow-fork-preview` | `false` | Let a fork attempt a deploy. Almost always wrong |
| `allow-dispatch-from-any-ref` | `false` | Let a manual run deploy a non-default branch |
| `dry-run` | `false` | Resolve, plan and report without changing anything |

## Outputs

`mode` · `environment` · `url` · `deployed` · `verified` · `version-id` · `skipped` ·
`skip-reason` · `record-id`

---

## Honest skips, not confusing failures

A fork pull request cannot read secrets, and a repository that has adopted the workflow but not
been wired to a role has no credential. Both are *expected states*, and both would otherwise
surface as an authentication error that looks like a broken credential. Tremvok skips loudly
instead, with the reason on the job summary — and `skipped` / `skip-reason` as outputs.

## Failure isolation

A notification sink outage never fails a deploy that succeeded. Failing the job would invite a
re-run, and a re-run deploys again to fix a chat message. A *deploy* failure always fails the
job.

---

## The API

Optional, and only worth running once you want deployment history or notifications that do not
need a webhook secret in every repository.

```
GET  /healthz            liveness
POST /v1/deployments     record one deployment; fan out to Slack / Teams
GET  /v1/deployments     this repository's history
```

Authentication is a **GitHub Actions OIDC token and nothing else**. The `repository` a record
lands under is the token's claim rather than a body field, so "record a rollback against
someone else's repository" is not expressible. `allowed_owners` is deny-by-default: GitHub
issues an OIDC token to every repository on github.com, so a valid signature alone proves only
that the caller is *a* workflow.

It runs on AWS, entirely inside the always-free allowances — see
[terraform/README.md](terraform/README.md) for the numbers, the cost ceiling, and why an alarm
rather than a budget is the control that actually holds.

### Local development

Everything is provable without an AWS account:

```bash
make -C terraform dev     # LocalStack + build + apply + 25 end-to-end assertions
```

---

## Repository layout

| | |
|---|---|
| `action.yml` | the composite action — deliberately thin glue |
| `examples/` | ready-to-copy `deploy.yml` files, one per target |
| `scripts/*.sh` | the logic, `bats`-tested, portable to bash 3.2 |
| `src/tremvok/` | the FastAPI service |
| `scripts/build_api_zip.py` | **the one definition of what ships to Lambda** |
| `terraform/modules/tremvok-api/` | the infrastructure, free-tier capped |
| `terraform/localstack/` | the harness that proves the wiring |
| `tests/bats/`, `tests/` | shell tests and Python tests |

Contributor and agent guidance: [AGENTS.md](AGENTS.md) · [CLAUDE.md](CLAUDE.md) ·
[docs/](docs/index.md)

## Licence

MIT. Accent gemstone: **peridot** — the one common gem born in the mantle and carried to the
surface by an eruption, which is the deployment story in a stone.
