"""Shared fixtures. Nothing here reaches the network or a real AWS account.

The RSA keypair is generated per session with `cryptography` — a dev dependency, deliberately
absent from the Lambda package — so the tests sign genuine RS256 tokens and the verifier under
test is the same pure-stdlib one that runs in production.
"""

from __future__ import annotations

import base64
import json
import time

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from tremvok.oidc import JwksCache

TEST_ISSUER = "https://token.actions.githubusercontent.com"
TEST_AUDIENCE = "tremvok"
TEST_KID = "test-key-1"


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


@pytest.fixture(scope="session")
def signing_key() -> rsa.RSAPrivateKey:
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


@pytest.fixture(scope="session")
def jwks(signing_key: rsa.RSAPrivateKey) -> JwksCache:
    numbers = signing_key.public_key().public_numbers()
    cache = JwksCache(TEST_ISSUER)
    cache.seed({TEST_KID: (numbers.n, numbers.e)})
    return cache


@pytest.fixture
def make_token(signing_key: rsa.RSAPrivateKey):
    """Mint a signed OIDC token with whatever claims the test needs."""

    def _make(
        *,
        repository: str = "MagmaMoose/website",
        owner: str | None = None,
        audience: str = TEST_AUDIENCE,
        issuer: str = TEST_ISSUER,
        expires_in: int = 600,
        kid: str = TEST_KID,
        algorithm: str = "RS256",
        extra_claims: dict | None = None,
        sign: bool = True,
    ) -> str:
        header = {"alg": algorithm, "kid": kid, "typ": "JWT"}
        now = int(time.time())
        claims = {
            "iss": issuer,
            "aud": audience,
            "exp": now + expires_in,
            "iat": now,
            "nbf": now,
            "repository": repository,
            "repository_owner": owner if owner is not None else repository.split("/", 1)[0],
            "workflow": "Deploy",
            "run_id": "1234567890",
        }
        claims.update(extra_claims or {})
        header_b64 = b64url(json.dumps(header, separators=(",", ":")).encode())
        claims_b64 = b64url(json.dumps(claims, separators=(",", ":")).encode())
        signing_input = f"{header_b64}.{claims_b64}".encode("ascii")
        if sign:
            signature = signing_key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
        else:
            signature = b"\x00" * 256
        return f"{header_b64}.{claims_b64}.{b64url(signature)}"

    return _make


@pytest.fixture
def public_pem(signing_key: rsa.RSAPrivateKey) -> bytes:
    return signing_key.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    )
