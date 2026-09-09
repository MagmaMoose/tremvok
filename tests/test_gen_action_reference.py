"""Tests for gen_action_reference.py — covers the non-trivial helpers.

`docs/action-reference.md` is a build product, and the only thing guarding it was
`tests/test_input_targets.py::test_the_committed_reference_matches_action_yml`, whose
oracle is the committed page itself: regenerate it from a broken generator and both sides
move together, so it stays green. It also runs the script in a subprocess, so coverage
never sees the module. These tests call the generator in-process and pin what it should
*produce*, not merely that it reproduces whatever is checked in.
"""

from __future__ import annotations

import pathlib

import gen_action_reference as gen
import pytest
import yaml
from gen_action_reference import PERMISSIONS, applies_to, cell, default, render

ROOT = pathlib.Path(__file__).resolve().parents[1]
ACTION = yaml.safe_load((ROOT / "action.yml").read_text(encoding="utf-8"))


def section(doc: str, heading: str) -> str:
    """The body of one `## ` section.

    `target` and `mode` are both an input name and an output name, so an assertion that
    searches the whole page cannot tell the Inputs table from the Outputs table.
    """
    return doc.split(f"\n## {heading}\n", 1)[1].split("\n## ", 1)[0]


@pytest.fixture
def synthetic_action(tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch) -> pathlib.Path:
    """A three-input action.yml, so a row can be asserted literally rather than by shape.

    `render()` reads the module global at call time, which is what makes this swap work.
    """
    path = tmp_path / "action.yml"
    path.write_text(
        yaml.safe_dump(
            {
                "name": "synthetic",
                "inputs": {
                    "target": {"description": "Which deployment target."},
                    "aws-region": {
                        "description": "s3-cloudfront, lambda-zip: the region. auto | uv | pip"
                    },
                    "mode": {
                        "description": "What this run does. Defaults to <repo>-docs.",
                        "default": "auto",
                    },
                },
                "outputs": {"url": {"description": "The URL that was deployed."}},
            },
            sort_keys=False,
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr(gen, "ACTION", path)
    return path


def test_cell_escapes_pipes() -> None:
    assert cell("auto | uv | pip") == r"auto \| uv \| pip"


def test_cell_empty_string_returns_em_dash() -> None:
    assert cell("") == "—"


def test_cell_none_returns_em_dash() -> None:
    assert cell(None) == "—"


def test_cell_collapses_whitespace() -> None:
    assert cell("a  b") == "a b"


def test_cell_strips_leading_trailing_whitespace() -> None:
    assert cell("  hello  ") == "hello"


def test_cell_pipe_and_whitespace_combined() -> None:
    assert cell("foo  |  bar") == r"foo \| bar"


def test_angle_brackets_outside_code_spans_are_escaped() -> None:
    """`<repo>` outside backticks is parsed as an HTML tag and vanishes from the page.

    Same silent content loss as an unescaped pipe: markdownlint reports MD033, and what
    actually renders is "Defaults to -docs".
    """
    assert cell("Defaults to <repo>-docs.") == "Defaults to &lt;repo&gt;-docs."


def test_angle_brackets_inside_code_spans_are_left_alone() -> None:
    """Inside a code span they are already literal; `&lt;` there renders as the entity."""
    assert cell("Defaults to `<repo>-docs`.") == "Defaults to `<repo>-docs`."


def test_cell_collapses_a_multi_line_description_onto_one_row() -> None:
    """Action descriptions are `--help` prose and wrap over several lines. A raw newline
    inside a table cell ends the row, so everything after the first line disappears."""
    assert cell("One of:\n  auto\n  deploy") == "One of: auto deploy"


def test_asterisks_and_underscores_outside_code_spans_are_escaped() -> None:
    """`*` and `_` parse as emphasis: the markers are eaten and the text between them is
    italicised, so `a_b_c` renders as `abc` with no way to tell it was ever wrong."""
    assert cell("use * and _ freely") == r"use \* and \_ freely"


def test_asterisks_and_underscores_inside_code_spans_are_left_alone() -> None:
    """Backticks already suppress emphasis, and a backslash there renders literally."""
    assert cell("the `aws_region` var") == "the `aws_region` var"


def test_a_bare_url_is_wrapped_in_a_code_span() -> None:
    """A bare URL is valid markdown but bypasses the theme's link styling and makes
    markdownlint complain (MD034) about every description that carries one."""
    assert cell("See https://example.com/x for more.") == "See `https://example.com/x` for more."


def test_a_url_already_in_a_code_span_is_not_wrapped_twice() -> None:
    """Double-wrapping would close the span early and leak backticks into the cell."""
    assert cell("See `https://example.com/x`.") == "See `https://example.com/x`."


def test_default_of_an_unset_input_reads_not_set_rather_than_an_empty_cell() -> None:
    """An empty Default column reads as "nobody filled this in", not "there is no default"."""
    assert default("") == "not set"
    assert default(None) == "not set"


def test_default_of_a_set_input_is_rendered_as_a_code_span() -> None:
    assert default("auto") == "`auto`"
    assert default(False) == "`False`"


def test_the_target_input_is_labelled_the_selector_not_a_target_list() -> None:
    """`target` picks the target; it is never checked against itself. Listing it as
    applying to all five would claim the validator accepts `target` under every target,
    which is a different statement from the one that is true."""
    spec = {"description": "The deployment target."}
    assert applies_to("target", spec) == "the selector"


def test_an_input_with_no_target_marker_applies_to_all_targets() -> None:
    """`Post-deploy:` looks exactly like a target marker and is not one. The reference has
    to agree with `targets_for`, which is the parser the runtime validator reads."""
    spec = {"description": "Post-deploy: the URL."}
    assert applies_to("verify-url", spec) == "all"


def test_an_input_with_no_description_applies_to_all_targets() -> None:
    """A description-less input must not take the page build down with a KeyError."""
    assert applies_to("mystery", {}) == "all"


def test_a_target_specific_input_lists_its_targets_backticked_in_source_order() -> None:
    """The page must name exactly the targets the validator will accept the input under —
    documenting one it refuses is worse than documenting nothing."""
    spec = {"description": "s3-cloudfront, lambda-zip: the bucket."}
    assert applies_to("bucket", spec) == "`s3-cloudfront`, `lambda-zip`"


@pytest.mark.usefixtures("synthetic_action")
def test_every_declared_input_gets_a_row_carrying_its_applicability_and_default() -> None:
    """Pins the column order and that applies_to/default/cell are actually wired into the
    row — three helpers that are individually correct can still be assembled wrongly."""
    doc = render()
    assert "| `target` | the selector | not set | Which deployment target. |" in doc
    assert "| `mode` | all | `auto` | What this run does. Defaults to &lt;repo&gt;-docs. |" in doc


@pytest.mark.usefixtures("synthetic_action")
def test_a_pipe_in_a_description_is_escaped_in_the_rendered_row() -> None:
    """The failure that actually shipped: the tail of every `auto | uv | pip` description
    was dropped from the published page. cell() escaping it is not enough — the escape has
    to survive into the row."""
    assert (
        r"| `aws-region` | `s3-cloudfront`, `lambda-zip` | not set "
        r"| s3-cloudfront, lambda-zip: the region. auto \| uv \| pip |"
    ) in render()


@pytest.mark.usefixtures("synthetic_action")
def test_every_declared_output_gets_a_row_in_the_outputs_table() -> None:
    doc = render()
    assert "| `url` | The URL that was deployed. |" in section(doc, "Outputs")


@pytest.mark.usefixtures("synthetic_action")
def test_the_input_count_in_the_prose_matches_the_number_of_inputs() -> None:
    """The "takes N inputs" prose is derived from the same dict the table is built from. A
    hardcoded number is the exact drift ("the README said one thing, the generated page
    another") this generator exists to stop."""
    assert "takes 3 inputs" in render()


def test_the_real_action_yml_produces_exactly_one_input_row_per_input() -> None:
    """No input silently dropped from the page, and none listed twice."""
    body = section(render(), "Inputs")
    for name in ACTION["inputs"]:
        assert f"| `{name}` |" in body, name
    assert body.count("\n| `") == len(ACTION["inputs"])


def test_the_real_action_yml_produces_exactly_one_output_row_per_output() -> None:
    body = section(render(), "Outputs")
    for name in ACTION["outputs"]:
        assert f"| `{name}` |" in body, name
    assert body.count("\n| `") == len(ACTION["outputs"])


def test_every_target_gets_a_permissions_block_listing_its_grants() -> None:
    """A composite action cannot declare `permissions:`, so this is the caller's half of
    the contract. A target with no block means somebody's job fails on a 403 at the last
    step. The column padding is asserted too: it is what keeps the yaml block readable."""
    doc = render()
    for target, grants in PERMISSIONS.items():
        assert f"### `target: {target}`" in doc, target
        for grant, why in grants:
            assert f"  {grant:<22}# {why}" in doc, (target, grant)


def test_the_grants_each_target_actually_needs_are_the_ones_documented() -> None:
    """The test above renders PERMISSIONS and then looks for PERMISSIONS, so deleting a
    grant from the constant keeps it green while the page silently stops mentioning it.
    These are the four that a caller's job fails without, written out rather than derived.
    """
    doc = render()
    required = {
        "docs": ["contents: read", "pages: write", "id-token: write"],
        "s3-cloudfront": ["id-token: write", "pull-requests: write"],
        "lambda-zip": ["id-token: write", "pull-requests: write"],
        # checks: write is what lets the check run be a required one, which is the whole
        # mechanism behind apply-before-merge.
        "terragrunt": ["id-token: write", "checks: write", "pull-requests: write"],
        "ansible": ["contents: read", "pull-requests: write"],
    }
    for target, grants in required.items():
        block = doc.split(f"### `target: {target}`", 1)[1].split("```", 3)[1]
        for grant in grants:
            assert grant in block, (target, grant)


def test_the_github_pages_caveat_survives_into_the_page() -> None:
    """`target: docs` with `docs-target: github-pages` is the one target the action cannot
    finish alone — the caller has to run actions/deploy-pages — and the reference is where
    somebody finds that out before their deploy stops half-done."""
    doc = render()
    # The two facts a reader needs, not a phrase that any rewording would break: which
    # combination is affected, and what they have to run themselves.
    assert "`docs-target: github-pages`" in doc
    assert "actions/deploy-pages" in doc
    assert "`pages: write`" in doc
    assert "`github-pages`" in doc


def test_check_passes_against_the_committed_reference(capsys: pytest.CaptureFixture) -> None:
    """The CI gate itself, run in-process: the committed page equals what render() emits."""
    assert gen.main(["--check"]) == 0
    assert "up to date" in capsys.readouterr().out


def test_check_fails_and_names_the_regeneration_command_when_the_page_is_stale(
    tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture
) -> None:
    """A red check that does not say how to fix itself gets regenerated by guesswork."""
    out = tmp_path / "action-reference.md"
    out.write_text("stale\n", encoding="utf-8")
    monkeypatch.setattr(gen, "ROOT", tmp_path)  # OUT.relative_to(ROOT) needs both moved
    monkeypatch.setattr(gen, "OUT", out)

    assert gen.main(["--check"]) == 1
    captured = capsys.readouterr().out
    assert "is stale" in captured
    assert "python scripts/gen_action_reference.py" in captured


def test_check_treats_a_missing_page_as_stale_rather_than_crashing(
    tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A deleted page must fail the gate, not fail the job with a traceback."""
    monkeypatch.setattr(gen, "ROOT", tmp_path)
    monkeypatch.setattr(gen, "OUT", tmp_path / "action-reference.md")

    assert gen.main(["--check"]) == 1


def test_the_default_invocation_writes_the_generated_page(
    tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Without `--check` the script is the regeneration command CI tells people to run."""
    out = tmp_path / "action-reference.md"
    monkeypatch.setattr(gen, "ROOT", tmp_path)
    monkeypatch.setattr(gen, "OUT", out)

    assert gen.main([]) == 0
    assert out.read_text(encoding="utf-8") == render()
