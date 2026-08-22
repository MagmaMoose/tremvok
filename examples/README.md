# Ready-to-copy `deploy.yml`

One file per target. Copy the one you need to `.github/workflows/deploy.yml`, set the
repository variables it reads, and you are done — the logic lives in the versioned action, so a
fix reaches you through `@v1` rather than through nine copy-paste edits.

These are the files the [`standard`](https://github.com/MagmaMoose/standard) Copier template
should carry, gated on the product's `deploy_target`. Until then, add them by hand — and note
that [caldrith#54](https://github.com/MagmaMoose/caldrith/issues/54) is the piece that would
make template drift arrive as a pull request rather than as an archaeology exercise, which is
what stops these three files diverging again the way the hand-rolled ones did.

**Caldrith must not reconcile `deploy.yml` directly.** It owns files that must be *identical*
everywhere; these differ per product (hostname, bucket, verify URL). Two systems writing one
file take turns reverting each other, and every revert looks like somebody's commit.

| File | For |
|---|---|
| [`deploy-s3-cloudfront.yml`](deploy-s3-cloudfront.yml) | a built static site on S3 + CloudFront |
| [`deploy-lambda.yml`](deploy-lambda.yml) | a Lambda package |
| [`terragrunt.yml`](terragrunt.yml) | Terraform/Terragrunt stacks — the Atlantis replacement |

Three conventions they all inherit, so they leave the per-repo file:

- `runs-on: ${{ vars.SELFHOSTED_GITHUB_RUNNER || 'ubuntu-latest' }}` — GitHub-hosted minutes are
  metered on private repositories.
- **Never cancel a production deploy; do cancel a superseded preview.** That is what the
  `cancel-in-progress` expression says.
- `permissions: id-token: write` — the whole point is that no repository stores an AWS key.
