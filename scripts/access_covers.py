"""Decide whether a Cloudflare Access application covers a hostname.

Reads the `/accounts/{id}/access/apps` response on stdin and prints one of:

    YES              an application covers the hostname
    NO               none does — the site would be public
    ERROR:denied     the API refused the token
    ERROR:unreadable the response could not be parsed

Every outcome except YES is treated by the caller as "do not publish". That is the
point: a Cloudflare Pages project is served on the open internet at
`<project>.pages.dev` by default, so failing to *prove* the site is gated has to block,
not warn. Guessing in the permissive direction here publishes a private repo's docs.

Kept as a file rather than an inline `python3 -c` so it can be tested.
"""

from __future__ import annotations

import json
import sys


def _normalise(value: str) -> str:
    """A bare lowercase host: no scheme, no path, no trailing dot or slash."""
    value = (value or "").strip().lower().rstrip("/")
    for prefix in ("https://", "http://"):
        if value.startswith(prefix):
            value = value[len(prefix) :]
    return value.split("/", 1)[0].rstrip(".")


def covers(domain: str, hostname: str) -> bool:
    """True when an Access application on ``domain`` protects ``hostname``.

    An application on a parent domain covers its subdomains, which is how one
    application on a custom domain gates every docs site beneath it. A wildcard app
    (``*.example.com``) is the same rule written differently, and Cloudflare does allow
    it, so it is matched too — otherwise a site that IS gated reads as ungated and the
    deploy refuses for no reason anyone can see.
    """
    domain = _normalise(domain)
    hostname = _normalise(hostname)
    if not domain or not hostname:
        return False
    if domain.startswith("*."):
        # `*.example.com` covers a subdomain but not the apex, which is Cloudflare's rule.
        return hostname.endswith(domain[1:])
    return hostname == domain or hostname.endswith("." + domain)


def _app_domains(app: dict) -> list[str]:
    """Every hostname an application claims.

    `domain` is the classic field. Newer applications carry their hostnames in
    `destinations[]` (and `self_hosted_domains` before that), so reading only `domain`
    reports a genuinely gated site as ungated.
    """
    found: list[str] = []
    value = app.get("domain")
    if isinstance(value, str):
        found.append(value)
    for key in ("self_hosted_domains", "destinations"):
        for entry in app.get(key) or []:
            if isinstance(entry, str):
                found.append(entry)
            elif isinstance(entry, dict):
                uri = entry.get("uri") or entry.get("hostname") or entry.get("domain")
                if isinstance(uri, str):
                    found.append(uri)
    return found


def verdict(payload: str, hostname: str) -> str:
    try:
        data = json.loads(payload or "{}")
    except (ValueError, TypeError):
        return "ERROR:unreadable"
    if not isinstance(data, dict):
        return "ERROR:unreadable"
    if data.get("success") is False:
        return "ERROR:denied"
    if data.get("success") is not True:
        return "ERROR:unreadable"
    apps = data.get("result") or []
    if not isinstance(apps, list):
        return "ERROR:unreadable"
    for app in apps:
        if not isinstance(app, dict):
            continue
        if any(covers(d, hostname) for d in _app_domains(app)):
            return "YES"
    return "NO"


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        print("ERROR:unreadable")
        return 0
    print(verdict(sys.stdin.read(), args[0]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
