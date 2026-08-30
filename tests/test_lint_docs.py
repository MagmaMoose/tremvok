"""Tests for the repo-shape checks.

Each test builds a throwaway repo on disk rather than mocking the filesystem: every
check is defined by what is *in a repo*, so a fixture that fakes that away would be
testing something else.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from lint_docs import LINE_BUDGET, detect_profile, main

APACHE = "Apache License\nVersion 2.0, January 2004\n"
MIT = "MIT License\n\nCopyright (c) 2026 Magma Moose\n"
PROPRIETARY = "Proprietary License\n\nCopyright (c) 2026 Magma Moose (PTY) LTD\n"

ACTION_YML = """\
name: 'Thing'
description: 'Does a thing.'
author: 'Magma Moose'
branding:
  icon: 'upload-cloud'
  color: 'green'
runs:
  using: composite
  steps: []
"""

GOOD_ACTION_README = """\
# Thing

> **Does a thing.**

## Quickstart

```yaml
- uses: MagmaMoose/thing@v1
```

## What it does

- A thing.

## Most-used inputs

| Input | Default |
| --- | --- |
| `a` | `b` |

## Where it sits

Next to the other things.

## License

Apache-2.0, see [LICENSE](LICENSE).
"""

GOOD_SERVICE_README = """\
# Svc

> **A service.**

## What it is

A service, with two surfaces that talk over HTTP.

## Run it

```sh
docker run ghcr.io/magmamoose/svc:latest
```

## Documentation

[docs](https://example.com)

## License

Apache-2.0, see [LICENSE](LICENSE).
"""

NAV_MKDOCS = """\
site_name: Thing
site_url: https://magmamoose.github.io/thing/
nav:
  - Home: index.md
  - Setup: setup.md
"""


def build(
    tmp: Path,
    *,
    readme: str,
    licence: str = APACHE,
    action: str | None = ACTION_YML,
    pyproject: str | None = None,
    mkdocs: str | None = None,
) -> Path:
    (tmp / "README.md").write_text(readme, encoding="utf-8")
    (tmp / "LICENSE").write_text(licence, encoding="utf-8")
    if action is not None:
        (tmp / "action.yml").write_text(action, encoding="utf-8")
    if pyproject is not None:
        (tmp / "pyproject.toml").write_text(pyproject, encoding="utf-8")
    if mkdocs is not None:
        (tmp / "mkdocs.yml").write_text(mkdocs, encoding="utf-8")
    return tmp


def run(root: Path, *extra: str) -> int:
    return main(["--root", str(root), *extra])


# --------------------------------------------------------------------- profile


def test_root_action_yml_means_the_action_profile(tmp_path: Path) -> None:
    (tmp_path / "action.yml").write_text(ACTION_YML, encoding="utf-8")
    assert detect_profile(tmp_path) == "action"  # nosec: B101


@pytest.mark.parametrize("surface", ["pyproject.toml", "package.json", "Dockerfile"])
def test_a_manifest_means_service(tmp_path: Path, surface: str) -> None:
    (tmp_path / surface).write_text("{}", encoding="utf-8")
    assert detect_profile(tmp_path) == "service"  # nosec: B101


@pytest.mark.parametrize("surface", ["backend", "agent", "control-plane", "charts"])
def test_a_shipped_directory_means_service(tmp_path: Path, surface: str) -> None:
    """Regression: keying only on src/ filed dunmir and noctyr as spec-stage.

    Both ship real code (agent/ + control-plane/, backend/ + ios/) and neither has a
    src/ or a pyproject, so they were held to the 40-line spec budget they were never
    going to meet.
    """
    (tmp_path / surface).mkdir()
    assert detect_profile(tmp_path) == "service"  # nosec: B101


def test_nothing_shipped_means_spec(tmp_path: Path) -> None:
    (tmp_path / "README.md").write_text("# Nothing yet\n", encoding="utf-8")
    assert detect_profile(tmp_path) == "spec"  # nosec: B101


# --------------------------------------------------------------------- shape


def test_a_conforming_action_readme_passes(tmp_path: Path) -> None:
    build(tmp_path, readme=GOOD_ACTION_README)
    assert run(tmp_path) == 0  # nosec: B101


def test_over_budget_fails(tmp_path: Path) -> None:
    padded = GOOD_ACTION_README + "\n" * (LINE_BUDGET["action"] + 5)
    build(tmp_path, readme=padded)
    assert run(tmp_path) == 1  # nosec: B101


def test_budget_is_overridable(tmp_path: Path) -> None:
    padded = GOOD_ACTION_README + "\n" * 200
    build(tmp_path, readme=padded)
    assert run(tmp_path, "--readme-budget", "500") == 0  # nosec: B101


@pytest.mark.parametrize(
    "banned", ["Contents", "Examples", "Inputs", "Conventions", "Open questions"]
)
def test_banned_headings_fail(tmp_path: Path, banned: str) -> None:
    build(tmp_path, readme=GOOD_ACTION_README + f"\n## {banned}\n\nstuff\n")
    assert run(tmp_path) == 1  # nosec: B101


def test_most_used_inputs_is_not_caught_by_the_inputs_ban(tmp_path: Path) -> None:
    """The allowed section and the banned one differ by two words; keep them apart."""
    assert "## Most-used inputs" in GOOD_ACTION_README  # nosec: B101
    build(tmp_path, readme=GOOD_ACTION_README)
    assert run(tmp_path) == 0  # nosec: B101


def test_missing_required_section_fails(tmp_path: Path) -> None:
    build(tmp_path, readme=GOOD_ACTION_README.replace("## Quickstart", "## Getting going"))
    assert run(tmp_path) == 1  # nosec: B101


def test_required_sections_out_of_order_fail(tmp_path: Path) -> None:
    swapped = (
        GOOD_ACTION_README.replace("## Quickstart", "## TEMP")
        .replace("## What it does", "## Quickstart")
        .replace("## TEMP", "## What it does")
    )
    build(tmp_path, readme=swapped)
    assert run(tmp_path) == 1  # nosec: B101


# --------------------------------------------------------------------- licence


def test_readme_claiming_the_wrong_licence_fails(tmp_path: Path) -> None:
    """The live defect: three repos claimed MIT over an Apache-2.0 LICENSE."""
    build(
        tmp_path,
        readme=GOOD_ACTION_README.replace("Apache-2.0, see", "MIT License, see"),
        licence=APACHE,
    )
    assert run(tmp_path) == 1  # nosec: B101


def test_pyproject_claiming_the_wrong_licence_fails(tmp_path: Path) -> None:
    """nievah shipped exactly this: a Proprietary LICENSE and license = "MIT"."""
    build(
        tmp_path,
        readme=GOOD_ACTION_README,
        licence=PROPRIETARY,
        pyproject='[project]\nname = "x"\nlicense = "MIT"\n',
    )
    assert run(tmp_path) == 1  # nosec: B101


def test_agreeing_licences_pass(tmp_path: Path) -> None:
    build(
        tmp_path,
        readme=GOOD_ACTION_README,
        licence=APACHE,
        pyproject='[project]\nname = "x"\nlicense = "Apache-2.0"\n',
    )
    assert run(tmp_path) == 0  # nosec: B101


def test_an_incidental_mit_in_prose_is_not_a_licence_claim(tmp_path: Path) -> None:
    """Only a licence *section* counts; 'commit', 'limit' and a link to an MIT dep do not."""
    readme = GOOD_ACTION_README.replace(
        "Next to the other things.",
        "Wraps [tool](https://example.com), MIT License licensed. We commit often.",
    )
    build(tmp_path, readme=readme, licence=APACHE)
    assert run(tmp_path) == 0  # nosec: B101


# --------------------------------------------------------------------- links


def test_relative_docs_link_fails_for_an_action(tmp_path: Path) -> None:
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "setup.md").write_text("# Setup\n", encoding="utf-8")
    build(tmp_path, readme=GOOD_ACTION_README + "\nSee [setup](docs/setup.md).\n")
    assert run(tmp_path) == 1, "exists on disk, but 404s on the Marketplace listing"  # nosec: B101


def test_a_dangling_relative_link_fails(tmp_path: Path) -> None:
    build(tmp_path, readme=GOOD_ACTION_README + "\nSee [x](CONTRIBUTING.md).\n")
    assert run(tmp_path) == 1  # nosec: B101


def test_absolute_link_to_a_page_not_in_the_nav_fails(tmp_path: Path) -> None:
    readme = GOOD_ACTION_README + "\n[gone](https://magmamoose.github.io/thing/nope/)\n"
    build(tmp_path, readme=readme, mkdocs=NAV_MKDOCS)
    assert run(tmp_path) == 1  # nosec: B101


def test_absolute_link_to_a_nav_page_passes(tmp_path: Path) -> None:
    readme = GOOD_ACTION_README + "\n[setup](https://magmamoose.github.io/thing/setup/)\n"
    build(tmp_path, readme=readme, mkdocs=NAV_MKDOCS)
    assert run(tmp_path) == 0  # nosec: B101


# --------------------------------------------------------------------- marketplace


@pytest.mark.parametrize("drop", ["branding", "author"])
def test_marketplace_preflight_fails_without_required_metadata(tmp_path: Path, drop: str) -> None:
    """Marketplace rejects these at publish time, which is far too late to find out."""
    action = ACTION_YML
    if drop == "branding":
        action = action.split("branding:")[0] + "runs:\n  using: composite\n  steps: []\n"
    else:
        action = action.replace("author: 'Magma Moose'\n", "")
    build(tmp_path, readme=GOOD_ACTION_README, action=action)
    assert run(tmp_path) == 1  # nosec: B101


def test_marketplace_preflight_is_skipped_for_a_service(tmp_path: Path) -> None:
    build(
        tmp_path,
        readme=GOOD_SERVICE_README,
        action=None,
        pyproject='[project]\nname = "x"\n',
    )
    assert run(tmp_path) == 0  # nosec: B101


# --------------------------------------------------------------------- INHERIT


def test_declaring_markdown_extensions_under_inherit_fails(tmp_path: Path) -> None:
    """MkDocs REPLACES lists rather than merging them.

    Verified against mkdocs 1.6: a base declaring [admonition, tables] and a repo
    declaring [toc] resolves to [toc] plus MkDocs' own defaults. `admonition` is gone,
    with nothing reported. The visible symptom is a mermaid fence rendering as a wall
    of code.
    """
    mkdocs = "INHERIT: mkdocs.base.yml\nsite_name: Thing\nmarkdown_extensions:\n  - toc\n"
    build(tmp_path, readme=GOOD_ACTION_README, mkdocs=mkdocs)
    (tmp_path / "mkdocs.base.yml").write_text("theme:\n  name: material\n", encoding="utf-8")
    assert run(tmp_path) == 1  # nosec: B101


def test_inheriting_without_declaring_lists_passes(tmp_path: Path) -> None:
    mkdocs = "INHERIT: mkdocs.base.yml\nsite_name: Thing\nnav:\n  - Home: index.md\n"
    build(tmp_path, readme=GOOD_ACTION_README, mkdocs=mkdocs)
    (tmp_path / "mkdocs.base.yml").write_text("theme:\n  name: material\n", encoding="utf-8")
    assert run(tmp_path) == 0  # nosec: B101


def test_markdown_extensions_without_inherit_is_fine(tmp_path: Path) -> None:
    """Nothing to clobber when there is no base."""
    mkdocs = "site_name: Thing\nmarkdown_extensions:\n  - toc\n"
    build(tmp_path, readme=GOOD_ACTION_README, mkdocs=mkdocs)
    assert run(tmp_path) == 0  # nosec: B101
