# Action reference

```yaml
- uses: MagmaMoose/tremvok@v1
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
