# Common mistakes

Each of these cost real time. They are here so they cost it once.

## `x="$(… )"` where the last command is a false `[[ ]]` kills the script under `set -e`

A failing `[[ ]]` inside an `&&` list is exempt from `set -e`. A *command substitution* is not:
the substitution's exit status becomes the **assignment's** status, and an assignment is a
simple command. So this is fine:

```bash
[[ -n "$x" ]] && echo "$x"          # survives
{ echo a; [[ -n "" ]] && echo b; }  # survives
for i in 1; do [[ -n "" ]] && echo b; done   # survives
```

and this exits the script:

```bash
body="$(
  printf 'header\n'
  [[ -n "$optional" ]] && printf '%s\n' "$optional"   # ← false ⇒ assignment fails ⇒ set -e
)"
```

It only bites when the optional line is *absent*, which in `deploy-terragrunt.sh` meant: every
push event, immediately after a successful plan. Use `if` blocks inside `$( )`.

## FastAPI + `from __future__ import annotations` + a closure dependency = auth silently gone

`create_app()` defined `caller_repository` locally and used
`repository: Annotated[str, Depends(caller_repository)]`. With stringified annotations, FastAPI
resolves against the *module* globals, does not find the closure, and falls back to treating
`repository` as a required **query parameter**. Every authenticated route answered
`422 {"loc": ["query", "repository"]}` — the dependency never ran at all. Keep dependencies at
module level and hang collaborators off `request.app.state`.

## bash 4 syntax passes CI and fails on macOS runners

`${x,,}`, `${x^}`, `mapfile`, `readarray`, `declare -A` are bash 4. GitHub's macOS images ship
**bash 3.2** at `/bin/bash`, so these produce `bad substitution` on exactly one runner OS while
the Linux suite stays green. Use `tr '[:upper:]' '[:lower:]'` and `while IFS= read -r`.
`tests/bats/portability.bats` fails if any come back.

## `set -e` + `pipefail` + a loop that ends on a false test = a pipeline that "found nothing"

`find … | while read …; do is_stack "$d" && printf …; done | sort -u` exits non-zero whenever
the **last** iteration hits an excluded directory. With `pipefail` that fails the pipeline and
`set -e` ends the script. Discovery worked until somebody added a module that sorted last. Use
`if … then … fi` in loop bodies.

## `cmd | tee log` reports *tee's* exit code

The bug dunmir documented paying for: a failed deploy "reported success". `pipefail` is set in
every script here for this reason, and `terragrunt-run.sh` buffers to a file rather than piping.

## An empty build directory plus `aws s3 sync --delete` is an outage, and exits 0

`deploy-s3-cloudfront.sh` refuses to sync a source with no files in it. Do not add a flag to
override this.

## A cross-architecture Lambda package fails at the first request, not at deploy

`pydantic-core` is a compiled wheel. arm64 zip on an x86_64 function ⇒ clean apply, green plan,
`No module named 'pydantic_core._pydantic_core'` on request one. `build_api_zip.py --arch` and
the module's `architecture` must agree; the Makefile derives both from `uname -m`.

## A required check that never reports blocks the pull request forever

Which is why `deploy-terragrunt.sh` publishes the check run even when it discovers **zero**
stacks. "This change touches no Terraform" is a success, not silence.

## An unreadable review list is not "nobody approved"

`approval-gate.sh` exits non-zero when it cannot read the reviews. A caller that treats that as
an empty approver list will refuse to apply when it should — or, worse, a caller that treats an
API error as "no objections" will apply when it must not.
