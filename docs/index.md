# Tremvok

<!-- sources: action.yml, .github/workflows/docs.yml -->

**Ship it, prove it went live.**

Tremvok is the deploy-side counterpart to
[Diatreme](https://github.com/MagmaMoose/diatreme). Diatreme decides what version exists
and whether it is released; Tremvok gets it live and confirms it did.

The first target is documentation: build an MkDocs site strictly, publish it to GitHub
Pages, then request the published URL and fail if it does not answer.

## Why "verify" is a feature

`actions/deploy-pages` succeeds when GitHub **accepts** the artifact. That is not the
same as the site serving. A deploy can report green while the site 404s — a broken
`site_url`, a Pages source still set to a branch, a build that produced an empty
directory. Tremvok requests the published URL with backoff and fails on a non-2xx, so
green means readable rather than merely uploaded.

## Why two surfaces

A composite action cannot declare `permissions:` or `environment:`. `actions/deploy-pages`
requires `pages: write`, `id-token: write` and the `github-pages` environment, all of
which must be written by the calling workflow. So the split is not stylistic:

| Surface | Owns |
| --- | --- |
| **Action** (`MagmaMoose/tremvok@v1`) | Detect toolchain · build strictly · stage the Pages artifact |
| **Reusable workflow** (`…/.github/workflows/docs.yml@v1`) | The above, plus deploy and verify |

Use the action alone to build and stage but deploy somewhere else.

## Toolchain detection

`toolchain: auto` (the default) reads the repo rather than asking you to describe it:

| Found | Uses |
| --- | --- |
| `uv.lock` | `uv run --group docs mkdocs build --strict` |
| no `uv.lock`, a `requirements` file | `pip install -r …` then `mkdocs build --strict` |
| neither | fails with an actionable error rather than guessing |

Across MagmaMoose that one rule covers both cases: brimyr, chargate and draventis resolve
docs through a `docs` dependency-group in `uv.lock`; diatreme is not a uv project at all
and pins `docs/requirements.txt`.

## What the shape checks cover

Five hard errors, and deliberately no more. A linter with forty rules on a
one-maintainer org gets bypassed in week two.

| Check | Catches |
| --- | --- |
| README shape | budget, required section order, banned headings (`## Contents`, `## Examples`, a full `## Inputs` table) |
| Licence agreement | a README or `pyproject.toml` claiming a licence the LICENSE file contradicts |
| Link targets | dangling relative links, and `docs/*.md` links that 404 on a Marketplace listing |
| Marketplace preflight | missing `branding.icon` / `branding.color`, which Marketplace rejects at publish time |
| INHERIT clobber | a repo declaring `markdown_extensions` while inheriting a shared base |

Everything else is left to MegaLinter, which already runs markdownlint and link checking
on every pull request in every repo. Two places to keep in step is one too many.

That last check earns its place because the failure is silent. MkDocs merges `INHERIT`
dicts recursively but **replaces lists wholesale**: a base declaring
`[admonition, tables]` and a repo declaring `[toc]` resolves to `[toc]`, and `admonition`
is gone with nothing reported. The visible symptom is a page rendering as a wall of code
instead of a diagram.

## Next

- [Setup](setup.md) — the caller workflow, and the Pages prerequisite
- [Action reference](action-reference.md) — every input and output
- [Roadmap](roadmap.md) — what is scoped but not built
