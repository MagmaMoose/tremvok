"""GitHub Actions OIDC verification, with no dependency on a crypto library.

A workflow that calls Tremvok proves who it is with a GitHub Actions OIDC token rather than a
shared secret. That is the whole security model: there is no API key to mint, store, rotate or
leak in nine repositories, and the `repository` claim is *asserted by GitHub*, so a workflow
cannot record a deployment against someone else's repository by editing a request body.

**Deny by default.** GitHub issues an OIDC token to every repository on github.com, so a valid
signature proves only that the caller is *a* GitHub Actions workflow — not that it is one of
ours. `authorize()` is what makes the difference, and an empty allowlist denies everything.

Why this file implements RS256 itself
-------------------------------------
The obvious implementation is PyJWT, which needs `cryptography` — an 8 MB platform-specific
wheel that would have to be cross-built for the Lambda's architecture and would dominate the
package. Verifying an RSA PKCS#1 v1.5 signature is `pow(sig, e, n)` plus a constant-time
compare against a fixed prefix, which is 30 lines of `int` arithmetic and nothing else.

This is safe to hand-roll in a way that *signing* would not be: verification touches no secret,
so there is no timing channel to leak through, and the comparison is `hmac.compare_digest`
anyway. `tests/test_oidc.py` signs real tokens with `cryptography` (a dev dependency) and
checks that tampering with the header, the payload or the signature is rejected.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import threading
import time
import urllib.error
import urllib.request
from collections.abc import Callable

GITHUB_ISSUER = "https://token.actions.githubusercontent.com"

# ASN.1 DigestInfo for SHA-256, per RFC 8017 §9.2 note 1. The bytes are fixed; SHA-256 is the
# only digest GitHub signs OIDC tokens with, and accepting a second one would only widen the
# surface.
_SHA256_DIGEST_INFO = binascii.unhexlify("3031300d060960864801650304020105000420")

# Clock skew tolerated on exp/nbf/iat. GitHub tokens live 5-15 minutes, so a minute of slack
# costs nothing and stops a runner whose clock drifted from failing every deploy.
LEEWAY_SECONDS = 60


class OidcError(Exception):
    """Token rejected. The message is safe to log; it never contains the token."""


def _b64url_decode(segment: str) -> bytes:
    """Decode one base64url segment, tolerating the stripped '=' padding JWTs use."""
    padding = "=" * (-len(segment) % 4)
    try:
        return base64.urlsafe_b64decode(segment + padding)
    except (binascii.Error, ValueError) as exc:  # pragma: no cover - defensive
        raise OidcError("malformed base64url segment") from exc


def _b64url_int(segment: str) -> int:
    return int.from_bytes(_b64url_decode(segment), "big")


def rs256_verify(modulus: int, exponent: int, message: bytes, signature: bytes) -> bool:
    """Verify an RSASSA-PKCS1-v1_5 SHA-256 signature. Returns False, never raises."""
    key_size = (modulus.bit_length() + 7) // 8
    if len(signature) != key_size:
        return False

    signature_int = int.from_bytes(signature, "big")
    if signature_int >= modulus:
        return False

    recovered = pow(signature_int, exponent, modulus).to_bytes(key_size, "big")

    digest = hashlib.sha256(message).digest()
    tail = _SHA256_DIGEST_INFO + digest
    # EM = 0x00 || 0x01 || PS || 0x00 || T, and RFC 8017 requires at least 8 bytes of PS.
    # A key too small to hold that cannot have produced this signature.
    padding_length = key_size - len(tail) - 3
    if padding_length < 8:
        return False
    expected = b"\x00\x01" + b"\xff" * padding_length + b"\x00" + tail

    return hmac.compare_digest(recovered, expected)


class JwksCache:
    """The issuer's public keys, fetched over HTTPS and cached for the process lifetime.

    A Lambda execution environment serves many requests, so this is a per-container cache: one
    fetch per cold start rather than one per deployment. `kid` misses force a refetch, which is
    what makes key rotation a non-event — GitHub publishes the new key before it signs with it,
    but only a refetch will see it.
    """

    def __init__(
        self,
        issuer: str = GITHUB_ISSUER,
        *,
        ttl_seconds: int = 3600,
        loader: Callable[[], str | None] | None = None,
    ) -> None:
        self.issuer = issuer.rstrip("/")
        self.ttl_seconds = ttl_seconds
        # An optional source of a pinned JWKS document, tried before the network. Two real uses:
        # a GitHub Enterprise Server instance whose JWKS the function has no outbound route to,
        # and the LocalStack harness, which has no reachable issuer at all. Where it is
        # configured it *replaces* the fetch rather than supplementing it, so the function has
        # one fewer outbound dependency on the request path.
        self.loader = loader
        self._keys: dict[str, tuple[int, int]] = {}
        self._fetched_at = 0.0
        self._lock = threading.Lock()

    @property
    def jwks_uri(self) -> str:
        return f"{self.issuer}/.well-known/jwks"

    @staticmethod
    def parse(document: dict) -> dict[str, tuple[int, int]]:
        """JWKS JSON -> {kid: (modulus, exponent)}, skipping keys this verifier cannot use."""
        keys: dict[str, tuple[int, int]] = {}
        for key in document.get("keys", []):
            if key.get("kty") != "RSA" or "kid" not in key:
                continue
            if key.get("alg") not in (None, "RS256"):
                continue
            try:
                keys[key["kid"]] = (_b64url_int(key["n"]), _b64url_int(key["e"]))
            except (KeyError, OidcError):
                continue
        if not keys:
            raise OidcError("JWKS document contained no usable RSA keys")
        return keys

    def _load(self) -> dict[str, tuple[int, int]] | None:
        if self.loader is None:
            return None
        raw = self.loader()
        if not raw:
            return None
        try:
            return self.parse(json.loads(raw))
        except (ValueError, OidcError) as exc:
            raise OidcError("the pinned JWKS document is not usable") from exc

    def _fetch(self) -> dict[str, tuple[int, int]]:
        request = urllib.request.Request(  # noqa: S310 - scheme is fixed by the issuer config
            self.jwks_uri, headers={"accept": "application/json", "user-agent": "tremvok"}
        )
        if not self.jwks_uri.startswith("https://"):
            raise OidcError("refusing to fetch JWKS over a non-HTTPS URL")
        try:
            with urllib.request.urlopen(request, timeout=5) as response:  # noqa: S310
                document = json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, ValueError) as exc:
            raise OidcError(f"could not fetch JWKS from {self.jwks_uri}") from exc

        return self.parse(document)

    def key(self, kid: str) -> tuple[int, int]:
        with self._lock:
            stale = (time.time() - self._fetched_at) > self.ttl_seconds
            if kid not in self._keys or stale:
                self._keys = self._load() or self._fetch()
                self._fetched_at = time.time()
            if kid not in self._keys:
                raise OidcError(f"issuer published no key with kid {kid!r}")
            return self._keys[kid]

    def seed(self, keys: dict[str, tuple[int, int]]) -> None:
        """Install keys directly. Used by the tests and by the LocalStack harness, which has
        no reachable issuer."""
        with self._lock:
            self._keys = dict(keys)
            self._fetched_at = time.time()


def verify_token(
    token: str,
    *,
    audience: str,
    jwks: JwksCache,
    issuers: tuple[str, ...] = (GITHUB_ISSUER,),
    now: float | None = None,
) -> dict:
    """Verify a GitHub Actions OIDC token and return its claims.

    Raises `OidcError` for anything that is not a valid, unexpired token signed by the issuer
    and addressed to `audience`. Authorization is a separate step — see `authorize()`.
    """
    parts = token.split(".")
    if len(parts) != 3:
        raise OidcError("token is not a three-part JWT")
    header_b64, payload_b64, signature_b64 = parts

    try:
        header = json.loads(_b64url_decode(header_b64))
        claims = json.loads(_b64url_decode(payload_b64))
    except ValueError as exc:
        raise OidcError("token header or payload is not JSON") from exc
    if not isinstance(claims, dict) or not isinstance(header, dict):
        raise OidcError("token header or payload is not an object")

    # `alg: none` and HMAC algorithms are the classic JWT confusions: with HS256 an attacker
    # who knows the public key can sign their own token with it. Only RS256 is ever accepted.
    if header.get("alg") != "RS256":
        raise OidcError(f"unsupported token algorithm {header.get('alg')!r}")
    kid = header.get("kid")
    if not isinstance(kid, str) or not kid:
        raise OidcError("token header has no kid")

    modulus, exponent = jwks.key(kid)
    signing_input = f"{header_b64}.{payload_b64}".encode("ascii")
    if not rs256_verify(modulus, exponent, signing_input, _b64url_decode(signature_b64)):
        raise OidcError("token signature does not verify")

    issuer = claims.get("iss")
    if issuer not in issuers:
        raise OidcError(f"unexpected token issuer {issuer!r}")

    # `aud` is single-valued for GitHub, but the spec allows a list and a verifier that only
    # handles the string form silently accepts a list containing anything.
    token_audience = claims.get("aud")
    audiences = token_audience if isinstance(token_audience, list) else [token_audience]
    if audience not in audiences:
        raise OidcError("token audience does not match")

    current = time.time() if now is None else now
    expiry = claims.get("exp")
    if not isinstance(expiry, int | float):
        raise OidcError("token has no exp")
    if current > expiry + LEEWAY_SECONDS:
        raise OidcError("token has expired")
    not_before = claims.get("nbf")
    if isinstance(not_before, int | float) and current + LEEWAY_SECONDS < not_before:
        raise OidcError("token is not yet valid")

    return claims


def authorize(claims: dict, allowed_owners: frozenset[str]) -> str:
    """Return the caller's `owner/repo`, or raise if it is not one of ours.

    An empty allowlist denies everything. That is the deliberate failure mode: an unset
    `TREMVOK_ALLOWED_OWNERS` means the service was deployed without being told who may use it,
    and the safe reading of that is nobody rather than the whole of github.com.
    """
    repository = claims.get("repository")
    owner = claims.get("repository_owner")
    if not isinstance(repository, str) or not isinstance(owner, str) or "/" not in repository:
        raise OidcError("token carries no repository claim")
    if repository.split("/", 1)[0].lower() != owner.lower():
        raise OidcError("repository and repository_owner claims disagree")
    if owner.lower() not in allowed_owners:
        raise OidcError(f"owner {owner!r} is not allowed to record deployments here")
    return repository
