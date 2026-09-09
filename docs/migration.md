# Migrating to v2

<!-- sources: action.yml -->

v1 is the docs-only action. v2 is one action covering five targets, so the input surface had
to grow a selector and the docs inputs had to move out of the way of it.

**`@v1` keeps working exactly as it does today.** It is not deprecated by this and nothing
about it changes. Migrate when you want another target, or when you want the input
validation.

## What changed, and why

`target` at v1 meant *where the built site goes*. At v2 it means *what to deploy*, which is
the collision that forced a major:

```yaml
# v1
- uses: MagmaMoose/tremvok@v1
  with:
    target: cloudflare-pages

# v2
- uses: MagmaMoose/tremvok@v2
  with:
    target: docs
    docs-target: cloudflare-pages
```

Every other docs input gained a `docs-` prefix for the same reason: with five targets in one
action, a bare `toolchain` or `strict` cannot say whose it is. The prefix is also what the
validator keys on, so a misplaced input is caught rather than ignored.

## Renames

| v1 | v2 |
| --- | --- |
| `target` | `docs-target` |
| `toolchain` | `docs-toolchain` |
| `docs-group` | `docs-dependency-group` |
| `requirements` | `docs-requirements` |
| `python-version` | `docs-python-version` |
| `strict` | `docs-strict` |
| `site-dir` | `docs-site-dir` |
| `lint` | `docs-lint` |
| `profile` | `docs-profile` |
| `readme-budget` | `docs-readme-budget` |
| `markdownlint` | `docs-markdownlint` |
| `cloudflare-project` | `docs-cloudflare-project` |
| `cloudflare-account-id` | `docs-cloudflare-account-id` |
| `cloudflare-api-token` | `docs-cloudflare-api-token` |
| `cloudflare-branch` | `docs-cloudflare-branch` |
| `require-access` | `docs-require-access` |
| `stage-pages` | **removed** — it was already a deprecated alias; use `docs-target: none` |

`working-directory` and `checkout` are unchanged: they genuinely apply to every target.

## Outputs

| v1 | v2 |
| --- | --- |
| `toolchain` | `docs-toolchain` |
| `target` | `target` — now the selector you passed in, not the docs destination |
| `site-dir`, `page-url`, `deployment-url` | unchanged |

## The reusable workflows are gone

`.github/workflows/docs.yml` and `docs-github-pages.yml` were the v1 quickstart. They are
removed at v2: one action is the whole product, and a second callable surface for one target
only was a place for the two to disagree.

The half they carried that the action cannot is the Pages deploy: `actions/deploy-pages`
needs `pages: write` and the `github-pages` environment, and a composite action can declare
neither. That becomes a job in your own workflow — the shape is in [Setup](setup.md), and it
is about ten lines. It is the only place in the action where an `environment:` is
load-bearing; the Terragrunt apply gate is the action's own logic and needs none.

Callers who used `docs.yml` (Cloudflare Pages) need no second job at all: the action owns
that deploy outright.

## The subdirectory entrypoint is gone

`MagmaMoose/tremvok/deploy@v1` no longer exists. Its three targets are `target:
s3-cloudfront`, `target: lambda-zip` and `target: terragrunt` on the root action, with these
renames:

| `deploy/` | v2 |
| --- | --- |
| `role-to-assume` | `aws-role-to-assume` |
| `role-duration-seconds` | `aws-role-duration-seconds` |
| `bucket` | `s3-bucket` |
| `key-prefix` | `s3-key-prefix` |
| `delete-orphans` | `s3-delete-orphans` |
| `distribution-id` | `cloudfront-distribution-id` |
| `site-url` | `cloudfront-site-url` |
| `function-name` | `lambda-function-name` |
| `function-alias` | `lambda-function-alias` |
| `version-label` | `lambda-version-label` |
| `terraform-root` | `terragrunt-root` |
| `check-name` | `terragrunt-check-name` |

It never appeared in a release note, and the three files in `examples/` that pointed at it
were pointing at the root action anyway — which is a large part of why the surfaces merged.

## Behaviour changes worth knowing

- **A wrong input now fails the run.** At v1 an input the action did not declare produced a
  warning and was ignored. At v2 an input belonging to another target is an error naming
  both, raised before the checkout.
- **The Terragrunt apply uses the saved plan.** Plan writes `-out`, apply applies that file.
  When the saved plan has gone stale the run says so in the log and re-plans rather than
  refusing — `PLAN SOURCE:` in the log names which one ran.
- **A plan-only Terragrunt run reports success, not failure.** It deployed nothing on
  purpose. At v1 the notification called that a failed deploy.
- **`schedule` and `pull_request_review` resolve.** `mode: auto` used to fail on both, which
  broke the Terragrunt drift run on its own cron.
