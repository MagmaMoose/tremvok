# Contributing to Tremvok

Tremvok has two surfaces in one repository. They talk over HTTP and **neither imports the
other**; a change that couples them is the change to push back on.

| Surface | Lives in | Language | Tests |
|---|---|---|---|
| Composite action | `action.yml`, `scripts/*.sh` | bash (**3.2-compatible**) | `bats tests/bats` |
| API | `src/tremvok/` | Python 3.12, FastAPI | `uv run pytest` |
| Infrastructure | `terraform/` | OpenTofu ≥ 1.9 | `make -C terraform dev` |

## The rules that are not negotiable

1. **AWS only.** No Cloudflare, in any target or any hosted component. Anything that costs
   money outside the always-free allowances needs a decision recorded in `terraform/README.md`,
   not a default.
2. **bash 3.2.** GitHub's macOS runners ship it. No `${x,,}`, `${x^}`, `mapfile`, `readarray`,
   `declare -A`. `tests/bats/portability.bats` fails the build if one comes back.
3. **`action.yml` is glue.** Logic goes in `scripts/`, where it can be tested. If you find
   yourself writing a condition in YAML that is not a step `if:`, it belongs in a script.
4. **Notification sinks are failure-isolated.** They warn; they never fail the job. A *deploy*
   failure always fails the job.
5. **Secrets are SSM `SecureString`.** Never a Lambda environment variable (plaintext to
   `lambda:GetFunctionConfiguration`), never a Terraform resource (a secret in state).
6. **`scripts/build_api_zip.py` is the only definition of what ships.** CI must not assemble a
   package another way; a local build and a released artifact built differently is a difference
   nobody finds until production.
7. **Every guard gets a test that names the failure it prevents.** The tests here are the
   documentation of what went wrong once.

## Local validation

Run all four before opening a pull request:

```bash
shellcheck -S warning scripts/*.sh scripts/lib/*.sh
bats tests/bats
uv run ruff check . && uv run ruff format --check . && uv run pytest -q
make -C terraform validate
```

And, when you touched the API or the infrastructure:

```bash
make -C terraform dev      # LocalStack, end to end
```

## Adding a target adapter

1. `scripts/deploy-<target>.sh`, sourcing `lib/common.sh`, reading its inputs from environment
   variables, writing `deployed` and whatever else it produces with `tremvok::set_output`.
2. A step in `action.yml` gated on `inputs.target == '<target>'`.
3. `tests/bats/deploy_<target>.bats`, stubbing `aws` with `stub_script` so the exact command
   line is asserted — especially the flags that only matter when they are wrong.
4. Rows in the README input table, and the target's own section.
5. If the target can fail *silently*, a guard plus a test, plus a line in
   `.claude/COMMON_MISTAKES.md`.

## Changing the API's wire contract

`models.py` is the contract. `DeploymentIn` has `extra: "forbid"`, so adding a field to the
action's payload without adding it to the model is a 422, not a silent drop — which is the
behaviour we want. `repository` must never become a request field: it comes from the OIDC
token's claim, and that is what makes cross-repository writes inexpressible rather than merely
rejected.

## Commits and releases

- Conventional Commits. Branches are `<type>/<description>` or `<type>/<scope>/<description>`.
- Actions are SHA-pinned with a trailing `# vX.Y.Z` comment.
- Releases are cut by Diatreme (`versioning-tool: semantic-release-python`); the version lives
  in `src/tremvok/__init__.py` and nowhere else. Do not bump it by hand.
