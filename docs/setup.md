# Setting Tremvok up

<!-- sources: action.yml, README.md -->

Pick a target, add the job, grant the permissions that target needs. The
[action reference](action-reference.md) has every input and the exact permission block per
target; this page is the task-shaped version.

## The workflow, per target

### `github-pages`

`actions/deploy-pages` requires `pages: write` and the `github-pages` environment, and a
composite action can declare neither. So the action builds and stages the artifact, and a job
of yours publishes it. The environment name is fixed. GitHub creates `github-pages` when you
set the Pages source to "GitHub Actions", and `deploy-pages` expects that name, so this job
is boilerplate, not a decision:

```yaml
permissions: { contents: read }

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: MagmaMoose/tremvok@v2
        with:
          target: github-pages
          pages-strict: true

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

There's nothing to set for a pull request. GitHub Pages has one site and no preview
destination, so publishing to it is publishing, and a pull request (which resolves to
`mode: preview`) builds and checks without staging an artifact. A dry run does the same. The
build is the check, and it can't publish by accident.

Set **Settings → Pages → Source = "GitHub Actions"** once per repository.

### `cloudflare-workers`

```yaml
permissions: { contents: read, pull-requests: write }

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - run: npm run build                       # your build, not Tremvok's
      - uses: MagmaMoose/tremvok@v2
        with:
          target: cloudflare-workers
          artifact-path: dist                    # the Worker's asset directory
          cloudflare-api-token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          cloudflare-account-id: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
```

Two secrets, and no GitHub permission for the deploy itself: Cloudflare doesn't need one, so
`pull-requests: write` is there only for the sticky preview comment. Mint the API token from
Cloudflare's **"Edit Cloudflare Workers"** template rather than a hand-picked permission list,
or the first deploy of a custom domain fails on a permission nobody thought to grant. Pass the
account id as a secret too.

**Your `wrangler.toml` (or `wrangler.jsonc`) stays authoritative.** It owns the asset
directory, the routes, custom domains and 404 handling, so what ships matches what's reviewed
in the repository. The inputs are overrides for the few things a workflow legitimately varies
between runs: `artifact-path` is passed as `--assets`, `cloudflare-worker-name` as `--name`,
`cloudflare-env` as `--env`, and `cloudflare-config` points at the file when it isn't where
Wrangler would look.

The mode decides which Wrangler command runs:

| Event | Mode | Wrangler |
|---|---|---|
| push to the default branch, or `workflow_dispatch` | `deploy` | `wrangler deploy`, live on the routes in your config |
| pull request | `preview` | `wrangler versions upload --preview-alias pr-<number>` |

**A preview takes no production traffic.** `versions upload` uploads the version and gives it
its own URL; it never moves the live routes, which a plain `deploy` would. The alias is the
pull request number, so the link in the comment is stable across pushes. A branch name isn't:
it changes, and it isn't always URL-safe.

Leave `cloudflare-main` empty for an assets-only Worker, which is the shape that serves files
straight from the edge with no cold start, no code in the request path, and asset requests
that aren't billed as invocations. Set it to your entry point for a Worker that runs code, and
add `cloudflare-build-command` if that code needs bundling first.

Wrangler is pinned (`cloudflare-wrangler-version`, 4.114.0 by default), because the tool that
publishes to production isn't a floating dependency. The action installs Node 24 for it:
Wrangler 4 declares `engines.node >= 22`, and on 20 it installs cleanly and then refuses to
run.

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

An independent pull-request approval is the apply authorisation. Approving applies the
stacks, and the check run turns green once they are applied. `terragrunt-apply-operators`
names who may force one by hand; empty means nobody, so that path fails closed.

The gate is the action's own (`scripts/approval-gate.sh`), so it needs no GitHub
`environment:`. An unapproved run plans and stops; the role session it holds applies nothing.
Add an `environment:` to your job only if you want what an environment adds beyond the gate:
a wait timer, or secrets scoped to it.

### `ansible`

```yaml
permissions: { contents: read, pull-requests: write }
```

Runner-agnostic on purpose. A fleet reachable only from inside a private network needs a
self-hosted runner that sits in it. That's your `runs-on:`, and the action does not check,
because the same playbook against reachable hosts is a legitimate use.

## An IAM role the workflow can assume

For the three AWS targets. Tremvok authenticates with this run's GitHub OIDC token; nothing
is stored in the repository. The role's trust policy is what decides who may use it. Scope
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

Grant it only what the target needs. For `s3-cloudfront` that's `s3:PutObject`,
`s3:DeleteObject`, `s3:ListBucket` on the one bucket, and `cloudfront:CreateInvalidation` on
the one distribution.

## Secrets for the ansible target

The SSH key and the vault password arrive as repository or organisation secrets, passed as
inputs. Tremvok masks each on receipt, writes them to `0600` files under `$RUNNER_TEMP`, and
removes them with a trap that fires however the step exits, nothing reaches a command line,
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

### Reading them from HashiCorp Vault instead

If a secret already lives in Vault, name it by reference rather than copying it into a GitHub
secret. A copy is a second thing to rotate, and the failure mode is silent: you rotate in
Vault, the copy keeps working, and nobody finds out until it doesn't.

```yaml
with:
  target: ansible
  ansible-playbook: ansible/site.yml
  ansible-inventory: ansible/inventory/production
  vault-addr: https://vault.example.com:8200
  vault-token: ${{ secrets.VAULT_TOKEN }}
  ansible-ssh-private-key-vault: secret/data/team/app#ssh_private_key
```

The reference is `<path>#<field>`. Each `-vault` input is the **alternative** to the literal
one, never a supplement: setting `ansible-ssh-private-key` and `ansible-ssh-private-key-vault`
together fails rather than quietly preferring one. `ansible-ssh-known-hosts-vault` and
`ansible-vault-password-vault` work the same way.

!!! note "Two different products called Vault"
    `vault-addr` and `vault-token` are HashiCorp Vault. `ansible-vault-password` is
    ansible-vault, the file-encryption tool, and has nothing to do with it. That's why the
    HashiCorp inputs aren't prefixed `ansible-vault-`: it would read as the wrong one.

KV v1 and v2 both work without you saying which: v2 nests the payload one level deeper, and
both shapes are tried. If you're on v2 the path needs its `/data/` segment
(`secret/data/team/app`, not `secret/team/app`), and a 404 says so.

The token needs read on the paths you reference and nothing else. What comes back is masked
and written to a `0600` file exactly like a literal secret, on the same single code path, and
a failed read fails the run rather than continuing with no key.

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
