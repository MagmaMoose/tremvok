# Troubleshooting

<!-- sources: scripts/, src/tremvok/oidc.py, src/tremvok/api/app.py -->

Every entry here is an error the action or the API actually emits. The message is quoted as it
appears in the log.

## Inputs and setup

### `these inputs do not apply to target: <target>`

The run passed an input belonging to a different target. The log names each one and where it
belongs, and lists all of them at once so you fix them in one pass rather than one per run.

This fires before the checkout, so it costs a couple of seconds. Check the "Applies to" column
in the [action reference](action-reference.md), or drop the input.

There's one thing this can't catch: an input set explicitly to the value it already defaults to.
GitHub gives a composite action no way to tell "unset" from "set to the default". An input
holding its default changes nothing, so the blind spot is harmless.

### `unknown target '<value>'`

`target` accepts `github-pages`, `s3-cloudfront`, `lambda-zip`, `terragrunt`, `ansible` or
`cloudflare-workers`. The message lists them. There's no default, on purpose: guessing
`github-pages` would silently build a site for someone who meant to deploy a Lambda.

### `Tremvok skipped: this pull request comes from a fork`

Working as designed. A fork can't read your secrets, so the credential is empty and the deploy
would fail with an authentication error that looks like a broken credential rather than a policy
doing its job. The run reports a skip with the reason instead.

`allow-fork-preview: true` exists and is almost always wrong: it converts an honest skip into an
auth error.

### `Tremvok skipped: no AWS credential is available for target: <target>`

Only the three AWS targets raise this. Set `aws-role-to-assume`, or configure credentials in an
earlier step. `github-pages`, `cloudflare-workers` and `ansible` never see it: they publish
somewhere else, so demanding an AWS credential would skip a run that never needed one.

### `role-to-assume is set but this job cannot mint an OIDC token`

Add `permissions: id-token: write` to the job. Without it, GitHub doesn't hand the runner a
token to exchange.

### `STS refused to assume <role-arn>. Check the role's trust policy allows this repository and ref.`

The role exists and the token is valid, but the trust policy doesn't match this run. The usual
cause is a `sub` condition scoped to a branch the run isn't on. See
[Setup](setup.md#an-iam-role-the-workflow-can-assume) for the policy shape, and note the
`StringLike` on `sub` should carry a `ref:` prefix rather than `repo:owner/name:*`.

## `target: github-pages`

### `no uv.lock and no docs/requirements.txt — cannot tell how to install MkDocs`

Detection looks for `uv.lock` first, then the file named by `pages-requirements`. If your repo
has neither, set `pages-toolchain` to `uv` or `pip` explicitly.

### `pages-toolchain must be auto, uv or pip (got '<value>')`

The only three values. `auto` is the default and is right almost always: `uv.lock` in the tree
is the fact, and a caller restating it in config is one more thing that can disagree with the
repo.

### `no mkdocs.yml in <dir> — nothing to build`

`working-directory` doesn't point at the directory holding `mkdocs.yml`.

### The build passed but nothing was staged for the Pages deploy

Expected on a pull request, and there's no input to change it. GitHub Pages has one site and
no preview destination, so a run in `mode: preview` (which is what a pull request resolves to)
builds and checks without staging an artifact, and `dry-run: true` does the same. The run
summary says `staging a Pages artifact: false`; the log says `stage-pages=false`. On a push
to the default branch both say true.

If a push also staged nothing, check the job summary for a skip: a fork pull request and an
unwired repository both report one with a reason.

## `target: s3-cloudfront` and `target: lambda-zip`

### `artifact-path '<path>' is not a directory` / `is not a file` / `is empty`

The build step didn't produce what the deploy expects: a directory for `s3-cloudfront`, a `.zip`
for `lambda-zip`.

!!! warning "The empty-directory refusal is deliberate"
    An empty build directory plus `aws s3 sync --delete` empties the live site and exits `0`.
    The refusal is what stands between a build that quietly produced nothing and an outage. Don't
    add a flag to override it.

### `Lambda reports CodeSha256 <a> but the artifact is <b>. The function is not running the package this run built.`

The update was accepted and the function is serving different code. Usually a concurrent deploy,
or an update that targeted a different function or alias. "The API accepted my request" is not
"the function runs my code", which is why this check exists.

### `No module named 'pydantic_core._pydantic_core'` on the first request

A cross-architecture package. The deploy succeeded because nothing loads the code until a request
arrives. `build_api_zip.py --arch` and the module's `architecture` must agree. See
[Configuration](configuration.md#terraform-module-variables).

Unzipping the package on a macOS laptop and importing it fails the same way, and that one is
correct: the builder fetches Linux wheels for the function's architecture.

## `target: cloudflare-workers`

### `CLOUDFLARE_API_TOKEN is required` / `CLOUDFLARE_ACCOUNT_ID is required`

The log names the input that supplies each one, `cloudflare-api-token` and
`cloudflare-account-id`. Both are checked before anything is installed or built, so a missing
secret costs a second rather than a build. The usual cause is a fork pull request, which can't
read secrets, and which the preflight skip normally catches first.

Mint the token from Cloudflare's "Edit Cloudflare Workers" template rather than a hand-picked
permission list, or the first deploy of a custom domain fails on a permission nobody thought
to grant. `WRANGLER_VERSION is required` is the same guard: you blanked
`cloudflare-wrangler-version`, and the tool that publishes to production is not a floating
dependency.

### `artifact-path '<path>' is not a directory`

`artifact-path` is the Worker's asset directory for this target, passed to Wrangler as
`--assets`. Either the build step didn't run, or it wrote somewhere else. Leave the input empty
if the asset directory in your Wrangler config is the one you want.

### `artifact-path '<path>' has no files in it. Refusing to publish an empty asset directory over a site that is currently serving.`

The build produced nothing and the deploy would have replaced a working site with it. Same
refusal as the S3 target, for the same reason.

!!! warning "There is no flag to override this"
    A build that quietly produced nothing is indistinguishable from a successful one right up
    until the site is empty. The refusal is the only thing standing between the two.

### `preview mode needs a preview-alias`

`mode: preview` uploads a version under an alias, and the alias is what makes that version
reachable without touching production. It's `pr-<number>`, resolved from the event, so this
means preview mode with no pull request behind it: usually `mode: preview` forced on a push.
Let `mode: auto` resolve it, or run `mode: deploy`.

You normally hit the earlier form of the same problem first, `preview mode needs a
pull-request number or an explicit preview-alias`. The deploy step checks again anyway,
because a preview uploaded under no alias is a version nobody can reach.

### `unsupported mode '<mode>' for target cloudflare-workers (expected deploy or preview)`

`mode: rollback` is accepted by `s3-cloudfront` and `lambda-zip`, where it behaves exactly
like a deploy: it publishes whatever artifact you hand it. Point `artifact-path` (or
`lambda-version-label`) at the older build and it re-publishes that. What no target does
is look up deployment history and pick the previous version for you. `terragrunt`,
`ansible` and `cloudflare-workers` refuse the mode outright rather than pretend.

### `wrangler exited <n>`

Wrangler's own failure, and its output is above the message in the log. The code is
Wrangler's own, not `tee`'s: `pipefail` is set for exactly this, so a failed publish can't
report success. The two that aren't obvious from the output are a token that authenticates but
lacks a permission (mint it from the "Edit Cloudflare Workers" template), and a route or custom
domain already claimed by another Worker, which fails at the bind after a successful upload.

## `target: terragrunt`

### `terragrunt-stack-env line '<line>' has a pattern but no KEY=VALUE after it`

Every non-blank, non-comment line is `<glob>` then whitespace then `KEY=VALUE`. A pattern on
its own is refused rather than skipped, because a silently dropped line means a stack runs
with no credential and fails at `init` with something far less specific.

### A stack initialises against the wrong state account

Order decides it: the first matching line wins for a given key, so a `*` catch-all above a
`*/prod/*` pattern captures everything. Put the specific pattern first.

### `<n> stack(s) failed to plan`

The pull-request comment carries a redacted excerpt per stack. Nothing applies while any stack
fails to plan, approval or not.

### `<actor> is not in terragrunt-apply-operators, so cannot force an apply`

`terragrunt-apply: force` skips the approval, so it needs its own authorisation. Empty
`terragrunt-apply-operators` means nobody, and the run refuses rather than applying on the
strength of a flag. The normal path is an independent pull-request approval and needs no list.

### The check run says `Apply required before merge` and stays amber

That's the intended state for a pull request with pending changes. It turns green once the stacks
are applied, which is what makes apply-before-merge enforceable. Get an independent approval:
approving applies the stacks.

### `could not read the reviews of #<n>`

The API call failed. The run refuses to apply rather than treating an unreadable review list as
"nobody objected". Retry, or check the token has `pull-requests: read`.

### The log says `the saved plan for <stack> has gone stale`

State moved between the plan and the apply. The run re-plans and applies the newer plan rather
than refusing, and says so. `PLAN SOURCE:` in the log names which plan actually ran. If you need
the reviewed plan or nothing, re-run the whole job so plan and apply are adjacent again.

### A scheduled run finds nothing

Discovery maps changed files to stacks by path, and a change under `modules/` maps to nothing on
purpose: a module has no state of its own. Guessing which stacks use it is how a small module
tidy-up ends up planning the whole estate. `terragrunt-scope: all` plans everything.

## `target: ansible`

### `Vault has nothing at '<path>' (404)`

On a KV v2 mount the read path carries a `/data/` segment that the UI path does not:
`secret/data/team/app`, not `secret/team/app`. That is the cause almost every time.

### `Vault refused the token for '<path>' (403)`

The token is valid and its policy doesn't grant read on that path. It needs read on the
paths you reference and nothing else.

### `Vault has '<path>' but no field '<field>' in it. Fields present: ...`

The reference is `<path>#<field>` and the field half doesn't exist. The message lists the
field names that do, never their values.

### `cannot reach Vault at <addr> (no response)`

From a private network this usually means the runner isn't on it. Check `runs-on` before
checking the address.

### `ansible-ssh-private-key and ansible-ssh-private-key-vault are both set`

Pick one. A literal secret and a Vault reference to the same thing is a mistake worth failing
on, rather than one silently winning.

### `the playbook is not idempotent: a second check-mode run still wants to change <n> task(s) on <hosts>`

The playbook applied cleanly and then, run again in check mode, still reported changes. That
means it doesn't converge. A zero exit only proves it ran.

Usual causes: a `command`/`shell` task with no `creates`/`changed_when`, or a template that
renders differently every run (a timestamp, an unsorted dict). Fix the task, or set
`ansible-verify-idempotence: false` if you accept the gap.

### `the playbook applied cleanly but could not be re-run in check mode`

A task with no check-mode support. Give it `check_mode: false`, or turn the verification off. The
fix is in the playbook, not in the deploy.

### `no playbook at <path>` / `no galaxy requirements file at <path>`

Paths are relative to `working-directory`. Both are checked before anything is installed.

### `host-key checking is off for this run`

A warning, not an error. You didn't supply `ansible-ssh-known-hosts`. It's a real downgrade, so
it's said out loud rather than defaulted quietly. Supply the entries for anything reachable from
a network you don't control.

## The API

### `401` on `POST /v1/deployments`

`authorize()` is deny-by-default. The token failed one of: signature, issuer, audience, or the
owner allowlist. Check `TREMVOK_ALLOWED_OWNERS` is set (empty denies everyone) and that
`api-audience` on the action matches `TREMVOK_OIDC_AUDIENCE` on the function.

The action never fails a deploy because the record didn't land. A deploy that worked and a record
that didn't is a successful deploy.

### `GET /healthz` passes but writes fail

A health check proves the function imported. It proves nothing about the write path, the table,
or the IAM policy. Test with a real signed `POST`. The LocalStack smoke suite exists to make that
cheap.
