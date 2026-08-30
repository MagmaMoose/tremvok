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
    assert covers("caldrith-docs.pages.dev", HOST) is True  # nosec: B101


def test_parent_domain_covers_subdomain() -> None:
    """One application on a custom domain can gate every docs site beneath it."""
    assert covers("magmamoose.com", "caldrith-docs.magmamoose.com") is True  # nosec: B101


def test_a_different_host_is_not_covered() -> None:
    assert covers("nievah-docs.pages.dev", HOST) is False  # nosec: B101


def test_a_suffix_that_is_not_a_domain_boundary_is_not_covered() -> None:
    """`evil-pages.dev` must not be read as covering `x.pages.dev`."""
    assert covers("pages.dev", "evilpages.dev") is False  # nosec: B101


def test_scheme_and_path_are_stripped() -> None:
    assert covers("https://caldrith-docs.pages.dev/docs", HOST) is True  # nosec: B101


@pytest.mark.parametrize("domain", ["", "   ", None])
def test_empty_domain_covers_nothing(domain: str | None) -> None:
    assert covers(domain or "", HOST) is False  # nosec: B101


# --------------------------------------------------------------------- verdict()


def test_no_apps_means_no() -> None:
    """The account's current state: zero Access applications."""
    assert verdict(api([]), HOST) == "NO"  # nosec: B101


def test_matching_app_means_yes() -> None:
    assert verdict(api([{"domain": HOST}]), HOST) == "YES"  # nosec: B101


def test_only_someone_elses_app_means_no() -> None:
    assert verdict(api([{"domain": "nievah-docs.pages.dev"}]), HOST) == "NO"  # nosec: B101


def test_refused_token_is_denied_not_permitted() -> None:
    """A 403 must block. Publishing because we could not check is the failure itself."""
    assert (  # nosec: B101
        verdict(json.dumps({"success": False, "errors": [{"code": 1010}]}), HOST) == "ERROR:denied"
    )


@pytest.mark.parametrize("payload", ["", "not json", "[]", "null", '{"result": []}'])
def test_anything_unparseable_blocks(payload: str) -> None:
    assert verdict(payload, HOST).startswith("ERROR")  # nosec: B101


def test_a_malformed_app_entry_does_not_grant_access() -> None:
    assert (  # nosec: B101
        verdict(json.dumps({"success": True, "result": ["nonsense", {}, {"domain": None}]}), HOST)
        == "NO"
    )


# ------------------------------------------------- shapes Nievah flagged on review


def test_wildcard_app_covers_a_subdomain() -> None:
    """`*.magmamoose.com` gates every docs site beneath it, and must read as covered.

    Missing this fails closed rather than open, but the refusal is baffling: the site
    genuinely IS gated and the deploy keeps refusing.
    """
    assert covers("*.magmamoose.com", "caldrith-docs.magmamoose.com") is True  # nosec: B101


def test_wildcard_does_not_cover_the_apex() -> None:
    """Cloudflare's own rule: `*.example.com` is subdomains, not the apex."""
    assert covers("*.magmamoose.com", "magmamoose.com") is False  # nosec: B101


def test_hostname_in_destinations_is_recognised() -> None:
    """Newer applications carry hostnames in `destinations[]`, not `domain`."""
    app = {"destinations": [{"type": "public", "uri": HOST}]}
    assert verdict(json.dumps({"success": True, "result": [app]}), HOST) == "YES"  # nosec: B101


def test_hostname_in_self_hosted_domains_is_recognised() -> None:
    app = {"domain": "something-else.pages.dev", "self_hosted_domains": [HOST]}
    assert verdict(json.dumps({"success": True, "result": [app]}), HOST) == "YES"  # nosec: B101


def test_a_trailing_dot_still_matches() -> None:
    assert covers("caldrith-docs.pages.dev.", HOST) is True  # nosec: B101
