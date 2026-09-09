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

`target` accepts `docs`, `s3-cloudfront`, `lambda-zip`, `terragrunt` or `ansible`. The message
lists them. There's no default, on purpose: guessing `docs` would silently build a site for
someone who meant to deploy a Lambda.

### `Tremvok skipped: this pull request comes from a fork`

Working as designed. A fork can't read your secrets, so the credential is empty and the deploy
would fail with an authentication error that looks like a broken credential rather than a policy
doing its job. The run reports a skip with the reason instead.

`allow-fork-preview: true` exists and is almost always wrong: it converts an honest skip into an
auth error.

### `Tremvok skipped: no AWS credential is available for target: <target>`

Only the three AWS targets raise this. Set `aws-role-to-assume`, or configure credentials in an
earlier step. `docs` and `ansible` never see it.

### `role-to-assume is set but this job cannot mint an OIDC token`

Add `permissions: id-token: write` to the job. Without it, GitHub doesn't hand the runner a
token to exchange.

### `STS refused to assume <role-arn>. Check the role's trust policy allows this repository and ref.`

The role exists and the token is valid, but the trust policy doesn't match this run. The usual
cause is a `sub` condition scoped to a branch the run isn't on. See
[Setup](setup.md#an-iam-role-the-workflow-can-assume) for the policy shape, and note the
`StringLike` on `sub` should carry a `ref:` prefix rather than `repo:owner/name:*`.

## `target: docs`

### `no uv.lock and no docs/requirements.txt, cannot tell how to install MkDocs`

Detection looks for `uv.lock` first, then the file named by `docs-requirements`. If your repo has
neither, set `docs-toolchain` to `uv` or `pip` explicitly.

### `no mkdocs.yml in <dir>, nothing to build`

`working-directory` doesn't point at the directory holding `mkdocs.yml`.

### `docs-target: cloudflare-pages needs docs-cloudflare-account-id`

Raised before the build rather than at the deploy step, so a missing credential costs a second
instead of the two minutes it takes to build a site nobody can publish.

### `docs-require-access is set, but no Cloudflare Access application covers <host>`

A Cloudflare Pages project is served on the open internet at `<project>.pages.dev` by default, so
"the repository is private" gates nothing. Create an Access application covering that hostname
(or a parent domain) and re-run. The check runs before the upload, because checking afterwards
would be checking after the leak.

If the message instead says the API token was refused or the response was unreadable, the run
also refuses to publish. An unverifiable answer is not a pass.

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

## `target: terragrunt`

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
