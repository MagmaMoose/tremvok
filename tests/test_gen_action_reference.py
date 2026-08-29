"""Tests for gen_action_reference.py — covers the non-trivial helpers."""

from __future__ import annotations

from gen_action_reference import cell


def test_cell_escapes_pipes() -> None:
    assert cell("auto | uv | pip") == r"auto \| uv \| pip"  # nosec: B101


def test_cell_empty_string_returns_em_dash() -> None:
    assert cell("") == "—"  # nosec: B101


def test_cell_none_returns_em_dash() -> None:
    assert cell(None) == "—"  # nosec: B101


def test_cell_collapses_whitespace() -> None:
    assert cell("a  b") == "a b"  # nosec: B101


def test_cell_strips_leading_trailing_whitespace() -> None:
    assert cell("  hello  ") == "hello"  # nosec: B101


def test_cell_pipe_and_whitespace_combined() -> None:
    assert cell("foo  |  bar") == r"foo \| bar"  # nosec: B101


def test_angle_brackets_outside_code_spans_are_escaped() -> None:
    """`<repo>` outside backticks is parsed as an HTML tag and vanishes from the page.

    Same silent content loss as an unescaped pipe: markdownlint reports MD033, and what
    actually renders is "Defaults to -docs".
    """
    assert cell("Defaults to <repo>-docs.") == "Defaults to &lt;repo&gt;-docs."


def test_angle_brackets_inside_code_spans_are_left_alone() -> None:
    """Inside a code span they are already literal; `&lt;` there renders as the entity."""
    assert cell("Defaults to `<repo>-docs`.") == "Defaults to `<repo>-docs`."
