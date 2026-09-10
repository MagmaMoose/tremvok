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
`environment:`. Add an `environment:` to your job only if you want what an environment adds
beyond the gate: a wait timer, or secrets scoped to it.

#### Letting a merge apply what it merged

Off by default. A push to the default branch plans and applies nothing unless you ask for
more:

```yaml
with:
  target: terragrunt
  terragrunt-apply-on-merge: 'true'
```

A push event carries no pull request, and the approval that authorises an apply belongs to the
pull request the commit was merged from. With this on, the run resolves that pull request from
the commit (`GET /repos/{repo}/commits/{sha}/pulls`, so squash, merge-commit and rebase merges
all resolve) and reads its reviews. Three outcomes, kept distinct on purpose:

| On the default branch, with apply-on-merge on | What happens |
| --- | --- |
| Merged from a pull request that had an independent approval | the affected stacks are applied, and the plan comment on that pull request is rewritten to the result |
| Merged without one, or pushed directly | plans and applies nothing, commenting on the merged pull request when there is one to comment on. The run exits `0` and the check run is `neutral` / `Planned; not applied` |
| The API could not be read, and there were pending changes | nothing is applied and the run **fails**, with a `failure` check run published first. An API outage must never read as "nobody approved" |

Where several merged pull requests are associated with one commit, the one whose base branch
is the branch that was pushed wins; among the rest, the oldest merge does. Neither unreadable
answer — the review list or the commit-to-pull-request lookup — refuses unless there was
something to apply, so a merge where every stack plans clean is not turned red by an API blip.
Both still warn, so a token missing `pull-requests: read` does not stay invisible until the
first merge that changes something.

An unapproved merge is reported rather than failed: it is a branch-protection matter, not a
broken build, and turning the default branch red does not fix it while leaving the stacks
unapplied and invisible would. The scheduled drift run keeps reporting them, and
`terragrunt-apply: force` applies them by hand.

`terragrunt-apply-on-merge` is deliberately not a value of `terragrunt-apply`. That input
answers "who may authorise an apply?"; this one answers "should a merge commit apply at all?".
With it on, the path needs `pull-requests: read` on the token, which the `pull-requests: write`
above already covers.

#### Failing fast on an unreachable endpoint

Terragrunt buffers plan output to a file, so a state backend or provider API the runner cannot
reach is not an error: it is a silent wait until `terragrunt-timeout` with an empty log.
`terragrunt-preflight-urls` probes each URL once, with an 8-second timeout, before the first
plan:

```yaml
with:
  target: terragrunt
  # A repository variable, so an unset one probes nothing and the block is safe to copy.
  terragrunt-preflight-urls: ${{ vars.TERRAGRUNT_PREFLIGHT_URLS }}
```

Any HTTP answer passes, `401` and `403` included: an unauthenticated probe of a credentialed
endpoint is supposed to be refused, and being refused proves something is there. Only a curl
code of `000` fails, which is DNS, connection refused, a connect timeout or a TLS failure. A
`5xx` warns and passes, so a transient `503` cannot make this a flake. When something is
unreachable the step prints the runner's egress IP, which is the fact you need next if the
endpoint is IP-allowlisted.

It proves reachability, not authorisation. A passing `403` does not mean your credential
works. Blank lines and `#` comments are ignored, and these URLs are printed into the run log,
so put nothing secret in them. A URL carrying userinfo (`https://user:password@host/`) is
refused outright, and the refusal names the line by its index and shows the URL with the
userinfo replaced, rather than echoing the line. Empty (the default) probes nothing.

#### Planning a named pull request by hand

`terragrunt-pull-request` points a manual run at one pull request: its reviews are what the
approval gate reads, its thread is where the plan comment goes, and its head commit is what
the check run is published against.

```yaml
on:
  workflow_dispatch:
    inputs:
      pull_request:
        description: 'Pull request number to plan or apply. Empty plans the default branch.'
        type: string
        default: ''

jobs:
  terragrunt:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<pinned sha>  # v7.0.1
        with:
          fetch-depth: 0
          # GitHub's merge of the pull request into its base: what lands on the default
          # branch if it merges. Empty falls back to the ref the run started from.
          ref: ${{ inputs.pull_request && format('refs/pull/{0}/merge', inputs.pull_request) || '' }}

      - uses: MagmaMoose/tremvok@v2
        with:
          target: terragrunt
          # Not optional here. Without it the action checks the workflow ref out again and
          # the merge tree is gone.
          checkout: false
          terragrunt-pull-request: ${{ inputs.pull_request }}
```

Checking out the right tree is yours, not Tremvok's: the action never fetches a merge ref, it
plans whatever is on disk. When the named pull request's head commit is not in that tree the
run warns and carries on, because `checkout: false` with a partial tree is a legitimate
choice. Two things fall out of this shape. You dispatch from the default branch and name the
pull request by number, so the "a manual run must start from main" rule still passes with no
exception. And `refs/pull/<n>/merge` does not exist while the pull request has conflicts, so
`actions/checkout` fails with git's own message before Tremvok runs at all.

`terragrunt-scope: auto` means the stacks that pull request touches whenever a pull request is
in scope, however it got there. `all` stays legal: plan the whole estate, gate on that pull
request's approval, comment on that pull request. A fork pull request is refused on this path,
exactly as the automatic one refuses fork code before it reaches a deploy credential.

### Per-stack state credentials

If your production state lives in a different storage account from the rest, which is a
deliberate blast-radius boundary rather than an accident, one credential can't reach both.
`terragrunt-stack-env` applies environment per stack:

```yaml
with:
  target: terragrunt
  terragrunt-stack-env: |
    */prd/*|*/prod/*  ARM_ACCESS_KEY=${{ secrets.PRD_STATE_KEY }}
    *                 ARM_ACCESS_KEY=${{ secrets.STATE_KEY }}
```

One `<glob> KEY=VALUE` per line. The first matching line wins for a given key, so the
specific pattern goes above the catch-all, exactly as it would in a `case`. Blank lines and
`#` comments are ignored, and a line with a pattern but no assignment fails the run rather
than being skipped.

The values are secrets, so they're passed to each invocation with `env` rather than exported
into the shell: one stack's credential never reaches the next stack's run. The apply gets the
same environment the plan got, which matters more than it sounds. A plan that reads state
with one credential and an apply that writes it with another is the worst version of this
bug, because the plan looks fine.

### `ansible`

```yaml
permissions: { contents: read, pull-requests: write }
```

Runner-agnostic on purpose. A fleet reachable only from inside a private network needs a
self-hosted runner that sits in it. That's your `runs-on:`, and the action does not check,
because the same playbook against reachable hosts is a legitimate use.

#### Letting the playbook read its own Vault secrets

`vault-addr` and `vault-token` let the action resolve `ansible-*-vault` references. They live
in the step's environment, and by default the action removes them before `ansible-playbook`
starts: a token scoped to the fields Tremvok reads would otherwise be usable by every task,
role and collection in the play, and nobody chose that.

`ansible-vault-passthrough: true` chooses it. `VAULT_ADDR`, `VAULT_TOKEN` and
`VAULT_NAMESPACE` are then passed to the playbook, so it can read its own secrets from the
same Vault instead of having them copied into a second store that quietly stops being
rotated. The token is masked. Without both `vault-addr` and `vault-token` set, nothing is
passed and the run says so. Nothing to do with ansible-vault the file-encryption tool; that is
`ansible-vault-password`.

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
