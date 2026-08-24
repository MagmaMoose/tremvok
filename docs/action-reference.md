# Action reference

<!-- sources: action.yml, .github/workflows/docs.yml -->

Generated from `action.yml` and the reusable workflow's `workflow_call` block. For the
task-shaped version, see [Setup](setup.md).

## Action inputs

`MagmaMoose/tremvok@v1` — all 9 inputs are optional.

| Input | Default | Description |
| --- | --- | --- |
| `working-directory` | `.` | Directory containing mkdocs.yml. |
| `toolchain` | `auto` | How to install MkDocs: auto (default) | uv | pip. `auto` picks uv when a uv.lock is present, otherwise pip against `requirements`. Detection exists so a caller does not have to declare per-repo what is already visible in the repo. |
| `docs-group` | `docs` | uv dependency-group holding the docs tooling (uv toolchain only). |
| `requirements` | `docs/requirements.txt` | Requirements file pinning the docs build (pip toolchain only). |
| `python-version` | `3.12` | Python version used to build the site. |
| `strict` | `true` | Build with `--strict`, so a broken internal link or a nav entry pointing at a missing file fails rather than publishing a site with holes in it. |
| `site-dir` | `site` | Directory the built site is written to. |
| `stage-pages` | `true` | Upload the built site as a GitHub Pages artifact, ready for actions/deploy-pages. Set false to build only and handle the upload yourself. |
| `checkout` | `true` | Run actions/checkout first. Set false if the caller already checked out. |

## Action outputs

| Output | Description |
| --- | --- |
| `site-dir` | Absolute path to the built site. |
| `toolchain` | The toolchain actually used: uv or pip. |
| `pages-staged` | true when a Pages artifact was uploaded. |

## Workflow inputs

`MagmaMoose/tremvok/.github/workflows/docs.yml@v1` — the action's inputs, plus the two
that only a workflow can act on.

| Input | Type | Default | Description |
| --- | --- | --- | --- |
| `working-directory` | `string` | `.` | Directory containing mkdocs.yml. |
| `toolchain` | `string` | `auto` | auto | uv | pip. auto detects uv.lock, else requirements. |
| `docs-group` | `string` | `docs` | uv dependency-group holding the docs tooling. |
| `requirements` | `string` | `docs/requirements.txt` | Requirements file pinning the docs build (pip toolchain). |
| `python-version` | `string` | `3.12` |  |
| `runs-on` | `string` | `ubuntu-latest` |  |
| `publish` | `boolean` | `True` | Deploy to GitHub Pages. Set false to build and verify only — the gate half without the publish half, which is what a pull-request check wants. |
| `verify` | `boolean` | `True` | After deploying, request the published URL and fail on a non-2xx. A deploy that reports success while the site 404s is the failure mode worth catching. |

## Required permissions

Declared by the **caller**, because a composite action cannot declare `permissions:`:

```yaml
permissions:
  contents: read      # checkout
  pages: write        # actions/deploy-pages
  id-token: write     # actions/deploy-pages
```

With `publish: false` only `contents: read` is needed.
