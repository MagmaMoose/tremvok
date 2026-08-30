"""Tests for the Cloudflare Access precondition.

Every case that is not a proven YES must block the deploy. A Pages project is public on
the open internet by default, so an ambiguous answer treated as "probably fine" publishes
a private repo's documentation.
"""

from __future__ import annotations

import json

import pytest

from access_covers import covers, verdict

HOST = "caldrith-docs.pages.dev"


def api(apps: list[dict] | None = None, success: bool = True) -> str:
    return json.dumps({"success": success, "result": apps or []})


# --------------------------------------------------------------------- covers()


def test_exact_host_is_covered() -> None:
    assert covers("caldrith-docs.pages.dev", HOST) is True


def test_parent_domain_covers_subdomain() -> None:
    """One application on a custom domain can gate every docs site beneath it."""
    assert covers("magmamoose.com", "caldrith-docs.magmamoose.com") is True


def test_a_different_host_is_not_covered() -> None:
    assert covers("nievah-docs.pages.dev", HOST) is False


def test_a_suffix_that_is_not_a_domain_boundary_is_not_covered() -> None:
    """`evil-pages.dev` must not be read as covering `x.pages.dev`."""
    assert covers("pages.dev", "evilpages.dev") is False


def test_scheme_and_path_are_stripped() -> None:
    assert covers("https://caldrith-docs.pages.dev/docs", HOST) is True


@pytest.mark.parametrize("domain", ["", "   ", None])
def test_empty_domain_covers_nothing(domain: str | None) -> None:
    assert covers(domain or "", HOST) is False


# --------------------------------------------------------------------- verdict()


def test_no_apps_means_no() -> None:
    """The account's current state: zero Access applications."""
    assert verdict(api([]), HOST) == "NO"


def test_matching_app_means_yes() -> None:
    assert verdict(api([{"domain": HOST}]), HOST) == "YES"


def test_only_someone_elses_app_means_no() -> None:
    assert verdict(api([{"domain": "nievah-docs.pages.dev"}]), HOST) == "NO"


def test_refused_token_is_denied_not_permitted() -> None:
    """A 403 must block. Publishing because we could not check is the failure itself."""
    assert (
        verdict(json.dumps({"success": False, "errors": [{"code": 1010}]}), HOST) == "ERROR:denied"
    )


@pytest.mark.parametrize("payload", ["", "not json", "[]", "null", '{"result": []}'])
def test_anything_unparseable_blocks(payload: str) -> None:
    assert verdict(payload, HOST).startswith("ERROR")


def test_a_malformed_app_entry_does_not_grant_access() -> None:
    assert (
        verdict(json.dumps({"success": True, "result": ["nonsense", {}, {"domain": None}]}), HOST)
        == "NO"
    )
