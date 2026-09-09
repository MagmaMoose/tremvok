# Ready-to-copy workflows

One file per target. Copy the one you need to `.github/workflows/`, set the repository
variables it reads, and you are done — the logic lives in the versioned action, so a fix
reaches you through `@v2` rather than through nine copy-paste edits.

| File | Target | For |
|---|---|---|
| [`docs.yml`](docs.yml) | `docs` | an MkDocs site on GitHub Pages |
| [`deploy-s3-cloudfront.yml`](deploy-s3-cloudfront.yml) | `s3-cloudfront` | a built static site on S3 + CloudFront |
| [`deploy-lambda.yml`](deploy-lambda.yml) | `lambda-zip` | a Lambda package |
| [`terragrunt.yml`](terragrunt.yml) | `terragrunt` | Terraform/Terragrunt stacks — the Atlantis replacement |
| [`ansible.yml`](ansible.yml) | `ansible` | a fleet configured over SSH |

They differ only in `target:` and that target's inputs. Everything shared — `mode`,
`verify-url`, the notification sinks — is spelled the same way in all five, which is the
point of one action rather than five.

Four conventions they inherit, so they leave the per-repo file:

- `runs-on: ${{ vars.SELFHOSTED_GITHUB_RUNNER || 'ubuntu-latest' }}` — GitHub-hosted minutes
  are metered on private repositories.
- **Never cancel a production deploy; do cancel a superseded preview.** That is what the
  `cancel-in-progress` expression says.
- `permissions: id-token: write` on the AWS targets — the whole point is that no repository
  stores an AWS key.
- A fork pull request never reaches a credential. The action skips one with a reason; the
  `if:` on the job is the belt for the targets where that matters most.

`docs.yml` is the only one with a second job, and only because `actions/deploy-pages`
requires `pages: write` and the `github-pages` environment — which a composite action cannot
declare. Every other target completes inside the action.
