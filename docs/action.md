# Action reference

```yaml
- uses: MagmaMoose/tremvok/deploy@v1
  with:
    target: s3-cloudfront
```

Complete, ready-to-copy workflows for each target live in
[`examples/`](https://github.com/MagmaMoose/tremvok/tree/main/examples).

## Permissions

| Need | Permission |
|---|---|
| Always | `contents: read` |
| `role-to-assume`, or `api-url` | `id-token: write` |
| Sticky pull-request comment | `pull-requests: write` |
| `target: terragrunt` (the check run) | `checks: write` |

## Modes

`mode: auto` derives the mode from the event:

| Event | Mode | Note |
|---|---|---|
| `push` to the default branch | `deploy` | a push to any other branch **fails** rather than guessing |
| `pull_request` | `preview` | alias defaults to `pr-<N>`, stable across pushes |
| `workflow_dispatch` | `deploy` | **pinned to the default branch** unless `allow-dispatch-from-any-ref` |
| `release` | `deploy` | |
| anything else | — | fails; set `mode` explicitly |

The `workflow_dispatch` pin is worth stating: without it, "Run workflow" from a topic branch
publishes that branch to production, is recorded as a normal deploy, and only surfaces when the
next real release appears to revert it.

## Targets

### `s3-cloudfront`

```yaml
with:
  target: s3-cloudfront
  artifact-path: dist
  bucket: ${{ vars.SITE_BUCKET }}
  distribution-id: ${{ vars.CLOUDFRONT_DISTRIBUTION }}
  site-url: https://magmamoose.com
  role-to-assume: ${{ vars.DEPLOY_ROLE_ARN }}
  aws-region: eu-west-1
```

Two sync passes: everything except `*.html|json|xml|txt|md` with
`public, max-age=31536000, immutable`, then the documents with
`public, max-age=0, must-revalidate`. Documents go **second** on purpose — they reference the
assets, so an asset must never be missing while its HTML is live.

A preview syncs to `<key-prefix>/previews/<alias>/` and invalidates only that path. One
wildcard invalidation, not one path per changed file: 1,000 invalidation paths a month are free
and the rest are billed.

Omit `distribution-id` and you get a warning, not silence — objects update in S3 while the CDN
serves the old ones until its TTL expires.

### `lambda-zip`

```yaml
with:
  target: lambda-zip
  artifact-path: dist/service.zip
  bucket: ${{ vars.ARTIFACT_BUCKET }}
  function-name: my-service
  function-alias: live
  version-label: ${{ needs.release.outputs.version }}
```

Uploads to `<key-prefix>/<version-label>.zip`, which is **immutable**: an existing key with
different bytes is a hard failure. An existing key with identical bytes is an idempotent re-run
and skips the upload.

`mode: preview` publishes a version and stops. `mode: deploy` moves the alias, creating it if
it does not exist.

### `terragrunt`

```yaml
permissions:
  contents: read
  id-token: write
  pull-requests: write
  checks: write
with:
  target: terragrunt
  terraform-root: terraform
  role-to-assume: ${{ vars.TERRAFORM_ROLE_ARN }}
```

On a pull request: discovers the stacks the changed files touch, plans each one, posts a rolling
comment with a status table and redacted plan excerpts, and publishes the `Terragrunt apply`
check run — `action_required` when there is anything to apply. Make that check **required** and
the merge is blocked until it goes green.

On a `pull_request_review` that is an approval: applies the pull request's merge result, then
turns the check green. Approving grants no new power — anyone who can approve can already merge,
and merging is what applies today. This only moves the apply to *before* the merge, where a
failure is still cheap.

A change under `modules/` maps to no stack, deliberately: guessing which stacks use a module
from its path is how a module tidy-up plans the whole estate. The scheduled `scope: all` run
covers it.

`checkout` needs `fetch-depth: 0` on push events — a shallow clone cannot reach the "before"
commit, so it reports zero changed files and discovers zero stacks.

## Verification

```yaml
with:
  verify-url: https://magmamoose.com/
  verify-header: content-security-policy
  verify-header-match: "default-src 'self'"
```

Retries `verify-attempts` times with `verify-delay` seconds between. Header names are matched
case-insensitively, because HTTP/2 lower-cases them and HTTP/1.1 does not — a case-sensitive
check passes on one protocol and fails on the other for the same server.

A `200` alone does not prove a deploy landed: the apex answers `200` from the *old* version too.
That is what the header assertion is for.

## Notifications

| Sink | Input | On by default |
|---|---|---|
| Sticky PR comment | `pr-comment` | `auto` — on for previews |
| Slack | `slack-webhook` | when set |
| Teams | `teams-webhook` | when set |
| Deployment record | `api-url` | when set |

All are failure-isolated and all run under `if: always()`, because a deploy that failed is
exactly when the humans most need to hear about it.

`notify: on-success | on-failure | always` gates the webhook sinks.

## Skips

`skipped` and `skip-reason` are outputs. A run skips when:

- the pull request comes from a **fork** — it cannot read secrets, so a deploy would fail with
  an authentication error that looks like a broken credential;
- **no AWS credential** is available and no `role-to-assume` is set — the repository has adopted
  the workflow but has not been wired up.

Both write the reason to the job summary. Neither fails the job.

## Inputs

Every input is optional; `target` decides which of the rest apply.

| Input | Default | What it does |
| --- | --- | --- |
| `target` | — | The deployment target. One of:   s3-cloudfront  Sync a built static site to S3 and invalidate CloudFront.   lambda-zip     Publish a Lambda package to S3, update the function, move an alias.   terragrunt     Discover, plan and (on an approval) apply Terragrunt stacks. |
| `mode` | `auto` | What this run should do. One of:   auto     (default) push to the default branch = deploy, pull_request = preview,            workflow_dispatch = deploy (pinned to the default branch).   deploy   Publish to the environment.   preview  Publish somewhere disposable; production is untouched.   rollback Re-publish a previously published version. |
| `artifact-path` | — | The built artifact: a directory for s3-cloudfront, a .zip for lambda-zip. Unused by terragrunt. |
| `environment` | — | Logical environment name, surfaced in notifications and the deployment record. Defaults to "production" (deploy) or "preview". |
| `working-directory` | `.` | Directory to run in. Paths in the other inputs are relative to it. |
| `aws-region` | — | AWS region. Falls back to the AWS_REGION environment variable. |
| `role-to-assume` | — | IAM role ARN to assume with this run's GitHub OIDC token. Strongly preferred over stored keys: the credential expires in an hour and the role's trust policy decides which repository and ref may use it. Requires `permissions: id-token: write`. Leave empty to use credentials an earlier step already configured. |
| `role-duration-seconds` | `3600` | Lifetime of the assumed-role session. |
| `bucket` | — | s3-cloudfront: the bucket serving the site. lambda-zip: the bucket holding published artifacts. |
| `key-prefix` | — | Key prefix within the bucket. Previews are placed under `<key-prefix>/previews/<alias>/`. |
| `distribution-id` | — | CloudFront distribution to invalidate after the sync. Empty means no invalidation — the CDN keeps serving the old objects until its TTL expires. |
| `site-url` | — | Base URL the distribution serves, used to build the URL reported in notifications. |
| `delete-orphans` | `auto` | Pass --delete to `aws s3 sync`, removing bucket objects with no local counterpart. `auto` (default) means yes. |
| `function-name` | — | lambda-zip: the function to update. |
| `function-alias` | `live` | lambda-zip: the alias moved to the new version in deploy mode. A preview publishes a version and does not move it. |
| `version-label` | — | lambda-zip: names the immutable S3 key (`<key-prefix>/<version-label>.zip`). Defaults to the short commit SHA. |
| `terraform-root` | `terraform` | terragrunt: directory the stacks live under. |
| `terragrunt-scope` | `auto` | terragrunt: `auto` (changed stacks on a PR/push, all on a schedule or dispatch), `all`, or `changed`. |
| `terragrunt-apply` | `auto` | terragrunt: `auto` (apply when the pull request has an independent approval), `never` (plan only), or `force`. |
| `check-name` | `Terragrunt apply` | terragrunt: name of the check run published against the head commit. Make it a required check to enforce apply-before-merge. |
| `verify-url` | — | Post-deploy: the URL that must answer. Empty skips verification. Catches the deploy that uploaded but did not bind — the one failure that otherwise looks green. |
| `verify-header` | — | Post-deploy: a response header that must be present on `verify-url` (e.g. content-security-policy). |
| `verify-header-match` | — | Post-deploy: an extended regex the `verify-header` value must match. |
| `verify-status` | `200` | Expected HTTP status from `verify-url`. |
| `verify-attempts` | `6` | How many times to try `verify-url` before failing. |
| `verify-delay` | `10` | Seconds between verification attempts. |
| `notify` | `always` | `always` (default), `on-success`, or `on-failure`. Applies to the webhook sinks. |
| `pr-comment` | `auto` | Sticky pull-request comment. `auto` (default) means on for preview mode and for the terragrunt target. |
| `slack-webhook` | — | Slack incoming-webhook URL. Empty means the sink is off. Never fails the deploy. |
| `teams-webhook` | — | Microsoft Teams incoming-webhook URL. Empty means the sink is off. Never fails the deploy. |
| `api-url` | — | Base URL of a Tremvok API to record this deployment with. Authenticates with a GitHub OIDC token, so the repository stores no credential. Empty means no record is kept. |
| `api-audience` | `tremvok` | OIDC audience the Tremvok API expects. |
| `auth-token` | `${{ github.token }}` | Token used for the pull-request comment and the check run. Needs `pull-requests: write` and, for the terragrunt target, `checks: write`. |
| `allow-fork-preview` | `false` | Let a fork pull request attempt a deploy. Off by default and almost always wrong: a fork cannot read secrets, so this only converts an honest skip into an auth error. |
| `allow-dispatch-from-any-ref` | `false` | Let a manual run deploy from a branch other than the default one. Off by default — publishing a topic branch to production usually is not what "Run workflow" meant. |
| `dry-run` | `false` | Resolve, plan and report without changing anything. |

## Outputs

| Output | What it is |
| --- | --- |
| `mode` | The resolved mode: deploy, preview or rollback. |
| `environment` | The resolved environment name. |
| `url` | URL of what was deployed, when the target produces one. |
| `deployed` | true when something was actually deployed (false for a skip). |
| `verified` | true when post-deploy verification ran and passed. |
| `version-id` | lambda-zip: the published Lambda version. |
| `skipped` | true when the run skipped (fork pull request, or no credential). |
| `skip-reason` | Why it skipped, in a sentence. |
| `record-id` | Identifier returned by the Tremvok API, when api-url is set. |
