# Tremvok

[![CI](https://github.com/MagmaMoose/tremvok/actions/workflows/docs-site.yml/badge.svg)](https://github.com/MagmaMoose/tremvok/actions/workflows/docs-site.yml)
[![Release](https://img.shields.io/github/v/release/MagmaMoose/tremvok?sort=semver&logo=github)](https://github.com/MagmaMoose/tremvok/releases)
[![Docs](https://img.shields.io/badge/docs-tremvok-brightgreen)](https://magmamoose.github.io/tremvok/)
[![License](https://img.shields.io/github/license/MagmaMoose/tremvok)](LICENSE)

> **Ship it, prove it went live.**

Tremvok is the deploy-side counterpart to
[Diatreme](https://github.com/MagmaMoose/diatreme): Diatreme decides *what version and
whether it is released*, Tremvok gets it *live and confirms it*. The first target is
documentation — build an MkDocs site strictly, publish it to GitHub Pages, then request
the published URL and fail if it does not answer.

**[Documentation](https://magmamoose.github.io/tremvok/)** ·
[Action reference](https://magmamoose.github.io/tremvok/action-reference/)

## Quickstart

The whole thing, as a reusable workflow:

```yaml
# .github/workflows/docs.yml
name: Docs
on:
  push:
    branches: [main]
    paths: ['docs/**', 'mkdocs.yml']
  workflow_dispatch:

jobs:
  docs:
    permissions:
      contents: read
      pages: write        # deploy-pages
      id-token: write     # deploy-pages
    secrets: inherit
    uses: MagmaMoose/tremvok/.github/workflows/docs.yml@v1
```

That is the entire caller. For GitHub Pages instead, call
`docs-github-pages.yml@v1` with `pages: write` and `id-token: write`, and set
**Settings → Pages → Source = "GitHub Actions"** once per repository.

## What it does

- **Detects your toolchain** — `uv.lock` present means `uv run --group docs`, otherwise
  pip against `docs/requirements.txt`. What is in the repo is the fact; restating it in
  config is one more thing that can disagree.
- **Builds strictly** — `--strict`, so a broken internal link or a nav entry pointing at
  a missing file fails instead of publishing a site with holes in it.
- **Deploys to Pages** — and only the workflow half does, because a composite action
  cannot hold the permissions this needs.
- **Checks the repo shape** — README budget and section order, licence agreement,
  link targets, Marketplace preflight. Plus markdownlint, which runs here because
  MegaLinter's security flavor carries no markdown linter.
- **Verifies it is serving** — requests the published URL with backoff and fails on a
  non-2xx. `deploy-pages` reports success when GitHub *accepts* the artifact, which is
  not the same as the site answering.

## Surfaces, and why

| | What it is | Owns |
| --- | --- | --- |
| **Action** — `MagmaMoose/tremvok@v1` | composite `action.yml` | Detect · build · stage the Pages artifact |
| **Reusable workflow** — `…/docs.yml@v1` | `workflow_call` | The above, plus a Cloudflare Pages deploy and verify |
| **Reusable workflow** — `…/docs-github-pages.yml@v1` | `workflow_call` | The above, plus a GitHub Pages deploy and verify |
| **Deploy action** — `MagmaMoose/tremvok/deploy@v1` | composite `deploy/action.yml` | Ship a built artifact to S3/CloudFront, Lambda or Terragrunt · verify · announce |
| **API** — `src/tremvok/` | FastAPI on Lambda | Record every deployment, fan notifications out, authenticated by GitHub OIDC |

A composite action **cannot declare `permissions:` or `environment:`**, and
`actions/deploy-pages` requires `pages: write`, `id-token: write` and the `github-pages`
environment. So a deploy can only ever be owned by a workflow. Use the action alone if
you want to build and stage but deploy some other way.

The **deploy action sits at a subdirectory entrypoint on purpose**. `action.yml` at the root
is the docs action's committed v1, and putting the AWS action there would have removed twelve
inputs every `@v1` consumer passes. A composite action can be referenced from any directory,
so both ship without either interface changing.

## Most-used inputs

Both surfaces take the same names.

| Input | Default | What it does |
| --- | --- | --- |
| `toolchain` | `auto` | `auto` · `uv` · `pip`. Override when detection would guess wrong. |
| `working-directory` | `.` | Where `mkdocs.yml` lives. |
| `docs-group` | `docs` | uv dependency-group holding the docs tooling. |
| `requirements` | `docs/requirements.txt` | Pin file for the pip path. |
| `publish` | `true` | *(workflow only)* Build and verify without deploying — what a PR check wants. |
| `verify` | `true` | *(workflow only)* Fail if the published URL does not answer 2xx. |

Every input and output → **[Action reference](https://magmamoose.github.io/tremvok/action-reference/)**

## Where it sits

[Diatreme](https://github.com/MagmaMoose/diatreme) releases ·
**Tremvok** deploys and verifies ·
[Chargate](https://github.com/MagmaMoose/chargate) gates security ·
[Brimyr](https://github.com/MagmaMoose/brimyr) gates tests

## Status

Docs deploy is the first target and is what ships today. Cloudflare Workers deploys and
the notification half (sticky PR comment, Slack, Teams) are scoped but not built —
see [Roadmap](https://magmamoose.github.io/tremvok/roadmap/).

Accent gemstone: **peridot**.

## Versioning

Pin `@v1` for the floating major, or a tag or SHA to freeze.

## Security · Contributing · License

[Report a vulnerability](https://github.com/MagmaMoose/tremvok/security/advisories/new) ·
[Contributing](https://github.com/MagmaMoose/.github/blob/main/CONTRIBUTING.md) ·
Apache-2.0, see [LICENSE](LICENSE).
