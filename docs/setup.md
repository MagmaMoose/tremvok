# Setup

<!-- sources: .github/workflows/docs.yml -->

## Prerequisite, once per repository

**Settings → Pages → Source → "GitHub Actions".** Without it the deploy step fails: Pages
will not accept a workflow artifact while the source is set to a branch.

You also need a `mkdocs.yml` at the repository root (or wherever
`working-directory` points), and one of:

- a `uv.lock` plus a `docs` dependency-group in `pyproject.toml`, or
- a `docs/requirements.txt` pinning `mkdocs-material`.

## The caller workflow

```yaml
# .github/workflows/docs.yml
name: Docs
on:
  push:
    branches: [main]
    paths:
      - 'docs/**'
      - 'mkdocs.yml'
      - '.github/workflows/docs.yml'
  workflow_dispatch:

jobs:
  docs:
    permissions:
      contents: read
      pages: write
      id-token: write
    uses: MagmaMoose/tremvok/.github/workflows/docs.yml@v1
```

The three permissions are required and must be declared **here**, by the caller — see
[why](index.md#why-two-surfaces).

## Checking a pull request without publishing

Build and verify the docs on a PR without deploying anything:

```yaml
on: [pull_request]

jobs:
  docs:
    permissions:
      contents: read
    uses: MagmaMoose/tremvok/.github/workflows/docs.yml@v1
    with:
      publish: false
```

!!! warning "Do not make this a required status check while it is path-filtered"

    A workflow filtered on `paths:` never starts for a PR that touches nothing matching,
    and a job that never starts never reports. Required checks wait forever for a status
    that is not coming, and the PR cannot merge — including the PR that removes the rule.
    Either drop the `paths:` filter or leave the check advisory.

## Using the action on its own

To build and stage but deploy elsewhere:

```yaml
- uses: MagmaMoose/tremvok@v1
  with:
    stage-pages: 'false'      # skip the Pages artifact entirely
    site-dir: 'site'
```

The `site-dir` output carries the absolute path to the built site.

## A monorepo, or docs in a subdirectory

```yaml
    with:
      working-directory: packages/docs
```

Every path input (`requirements`, `site-dir`) is resolved relative to it.
