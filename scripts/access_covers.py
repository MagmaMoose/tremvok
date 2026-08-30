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


def covers(domain: str, hostname: str) -> bool:
    """True when an Access application on ``domain`` protects ``hostname``.

    An application on a parent domain covers its subdomains, which is how one
    application on a custom domain can gate every docs site beneath it.
    """
    domain = (domain or "").strip().lower().rstrip("/")
    hostname = (hostname or "").strip().lower().rstrip("/")
    if not domain or not hostname:
        return False
    # Strip a scheme and any path, so an app recorded as a URL still matches.
    for prefix in ("https://", "http://"):
        if domain.startswith(prefix):
            domain = domain[len(prefix) :]
    domain = domain.split("/", 1)[0]
    return hostname == domain or hostname.endswith("." + domain)


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
        if isinstance(app, dict) and covers(app.get("domain", ""), hostname):
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
