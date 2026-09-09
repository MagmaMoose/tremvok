# Ready-to-copy workflows

One file per target. Copy the one you need to `.github/workflows/`, set the repository
variables it reads, and you are done: the logic lives in the versioned action, so a fix
reaches you through `@v2` rather than through nine copy-paste edits.

| File | Target | For |
|---|---|---|
| [`github-pages.yml`](github-pages.yml) | `github-pages` | an MkDocs site on GitHub Pages |
| [`deploy-s3-cloudfront.yml`](deploy-s3-cloudfront.yml) | `s3-cloudfront` | a built static site on S3 + CloudFront |
| [`deploy-lambda.yml`](deploy-lambda.yml) | `lambda-zip` | a Lambda package |
| [`terragrunt.yml`](terragrunt.yml) | `terragrunt` | Terraform/Terragrunt stacks, the Atlantis replacement |
| [`ansible.yml`](ansible.yml) | `ansible` | a fleet configured over SSH |
| [`cloudflare-workers.yml`](cloudflare-workers.yml) | `cloudflare-workers` | a Worker and its static assets, published with Wrangler |

They differ only in `target:` and that target's inputs. Everything shared (`mode`,
`verify-url`, the notification sinks) is spelled the same way in all six, which is the
point of one action rather than six.

Four conventions they inherit, so they leave the per-repo file:

- `runs-on: ${{ vars.SELFHOSTED_GITHUB_RUNNER || 'ubuntu-latest' }}`, because GitHub-hosted
  minutes are metered on private repositories.
- **Never cancel a production deploy; do cancel a superseded preview.** That is what the
  `cancel-in-progress` expression says.
- `permissions: id-token: write` on the AWS targets, because the whole point is that no
  repository stores an AWS key. `cloudflare-workers` needs none: it authenticates with an API
  token, and touches no AWS account.
- A fork pull request never reaches a credential. The action skips one with a reason; the
  `if:` on the job is the belt for the targets where that matters most.

`github-pages.yml` is the only one with a second job, and only because `actions/deploy-pages`
requires `pages: write` and the `github-pages` environment, which a composite action cannot
declare. Every other target completes inside the action.

Two of them have no destination input at all, for opposite reasons. `github-pages` has one
site and no preview destination, so a pull request builds without staging an artifact and
the mode is the whole decision. `cloudflare-workers` reads the asset directory, routes,
custom domain and 404 handling from your `wrangler.toml`, so what ships is what was reviewed
in the repository.
