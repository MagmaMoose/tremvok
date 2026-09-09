# Setting Tremvok up

<!-- sources: action.yml, README.md -->

Pick a target, add the job, grant the permissions that target needs. The
[action reference](action-reference.md) has every input and the exact permission block per
target; this page is the task-shaped version.

## The workflow, per target

### `docs`

```yaml
permissions: { contents: read }

jobs:
  docs:
    runs-on: ubuntu-latest
    steps:
      - uses: MagmaMoose/tremvok@v2
        with:
          target: docs
          docs-target: cloudflare-pages
          docs-cloudflare-account-id: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
          docs-cloudflare-api-token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          verify-url: https://my-project-docs.pages.dev
```

Cloudflare Pages needs no GitHub permission, so the action owns that deploy outright.

**GitHub Pages is the exception**, and the only one in the whole action:
`actions/deploy-pages` requires `pages: write` and the `github-pages` environment, and a
composite action can declare neither. So the action builds and stages the artifact, and a job
of yours publishes it. The environment name is fixed — GitHub creates `github-pages` when you
set the Pages source to "GitHub Actions", and `deploy-pages` expects that name — so this job
is boilerplate, not a decision:

```yaml
permissions: { contents: read }

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: MagmaMoose/tremvok@v2
        with:
          target: docs
          # A pull request has nothing to deploy, so build without staging an artifact:
          # the build is the check, and it can never publish by accident.
          docs-target: ${{ github.event_name != 'pull_request' && 'github-pages' || 'none' }}

  deploy:
    needs: build
    if: github.event_name != 'pull_request'
    runs-on: ubuntu-latest
    permissions: { pages: write, id-token: write }
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - id: deployment
        uses: actions/deploy-pages@v5
```

Set **Settings → Pages → Source = "GitHub Actions"** once per repository.

### `s3-cloudfront` and `lambda-zip`

See [`examples/`](https://github.com/MagmaMoose/tremvok/tree/main/examples). Both need
`id-token: write` for the role, and `pull-requests: write` for the sticky preview comment.

### `terragrunt`

```yaml
on:
  pull_request:
  pull_request_review: { types: [submitted, dismissed] }
  push: { branches: [main], paths: ['terraform/**'] }
  schedule: [{ cron: '0 5 * * 1-5' }]   # the weekday drift run

permissions:
  contents: read
  id-token: write
  pull-requests: write
  checks: write          # the check run that makes apply-before-merge enforceable
```

An independent pull-request approval is the apply authorisation — approving applies the
stacks, and the check run turns green once they are applied. `terragrunt-apply-operators`
names who may force one by hand; empty means nobody, so that path fails closed.

The gate is the action's own (`scripts/approval-gate.sh`), so it needs no GitHub
`environment:`. An unapproved run plans and stops; the role session it holds applies nothing.
Add an `environment:` to your job only if you want what an environment adds beyond the gate —
a wait timer, or secrets scoped to it.

### `ansible`

```yaml
permissions: { contents: read, pull-requests: write }
```

Runner-agnostic on purpose. A fleet reachable only from inside a private network needs a
self-hosted runner that sits in it — that is your `runs-on:`, and the action does not check,
because the same playbook against reachable hosts is a legitimate use.

## An IAM role the workflow can assume

For the three AWS targets. Tremvok authenticates with this run's GitHub OIDC token; nothing
is stored in the repository. The role's trust policy is what decides who may use it — scope
it to the repository **and** the refs that may deploy:

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
    "StringLike": { "token.actions.githubusercontent.com:sub": "repo:my-org/my-site:ref:refs/heads/main" }
  }
}
```

`StringLike` on `sub` with a `ref:` prefix, not `repo:owner/name:*`. The wildcard form lets a
pull request from a branch in the same repository assume a production deploy role.

Grant it only what the target needs — for `s3-cloudfront` that is `s3:PutObject`,
`s3:DeleteObject`, `s3:ListBucket` on the one bucket, and `cloudfront:CreateInvalidation` on
the one distribution.

## Secrets for the ansible target

The SSH key and the vault password arrive as repository or organisation secrets, passed as
inputs. Tremvok masks each on receipt, writes them to `0600` files under `$RUNNER_TEMP`, and
removes them with a trap that fires however the step exits — nothing reaches a command line,
where `ps` would show it.

```yaml
with:
  target: ansible
  ansible-playbook: ansible/site.yml
  ansible-inventory: ansible/inventory/production
  ansible-ssh-private-key: ${{ secrets.ANSIBLE_SSH_KEY }}
  ansible-vault-password: ${{ secrets.ANSIBLE_VAULT_PASSWORD }}
  ansible-ssh-known-hosts: ${{ secrets.ANSIBLE_KNOWN_HOSTS }}
```

`ansible-ssh-known-hosts` is optional and omitting it disables host-key checking, which the
run says out loud. Supply it for anything reachable from a network you do not control.

## (Optional) The Tremvok API

Only needed for deployment history, or for notifications that do not put a webhook URL in
every repository.

Deploying it is described in
[terraform/README.md](https://github.com/MagmaMoose/tremvok/blob/main/terraform/README.md);
the short version is that the module needs an artifact bucket, two SSM parameters written by
hand, and `allowed_owners` set to the GitHub owners you actually control. Then add
`api-url:` to the action and `permissions: id-token: write`. The repository stores nothing.

## Verify it, properly

After the first deploy of any new wiring:

```bash
curl -si https://your-site/ | head -1        # the site answers
```

and for the API, a **real signed POST**, not a `GET /healthz`. A health check passing proves
the function imported; it proves nothing at all about the write path, the table, or the IAM
policy. The LocalStack smoke suite exists to make that distinction cheap to test.
