"""The verifier is hand-rolled RSA, so these tests are the reason it is trustworthy.

Every case here is a way a JWT verifier is commonly wrong: accepting `alg: none`, accepting
HS256 signed with the public key, ignoring `aud`, ignoring `exp`, or trusting a body whose
signature covers a different header.
"""

from __future__ import annotations

import base64
import json
import time

import pytest

from tremvok.oidc import OidcError, authorize, rs256_verify, verify_token

from .conftest import TEST_AUDIENCE, TEST_ISSUER, b64url

ALLOWED = frozenset({"magmamoose"})


def test_valid_token_verifies(make_token, jwks):
    claims = verify_token(make_token(), audience=TEST_AUDIENCE, jwks=jwks)
    assert claims["repository"] == "MagmaMoose/website"


def test_tampered_payload_is_rejected(make_token, jwks):
    header, payload, signature = make_token().split(".")
    forged = json.loads(base64.urlsafe_b64decode(payload + "=="))
    forged["repository"] = "attacker/evil"
    swapped = f"{header}.{b64url(json.dumps(forged).encode())}.{signature}"
    with pytest.raises(OidcError, match="signature"):
        verify_token(swapped, audience=TEST_AUDIENCE, jwks=jwks)


def test_unsigned_token_is_rejected(make_token, jwks):
    with pytest.raises(OidcError, match="signature"):
        verify_token(make_token(sign=False), audience=TEST_AUDIENCE, jwks=jwks)


@pytest.mark.parametrize("algorithm", ["none", "HS256", "RS512", "ES256"])
def test_only_rs256_is_accepted(make_token, jwks, algorithm):
    # An `alg` the verifier does not implement must be refused *before* any signature work.
    # The classic bug accepts HS256 and validates it with the RSA public key, which every
    # caller already has.
    with pytest.raises(OidcError, match="algorithm"):
        verify_token(make_token(algorithm=algorithm), audience=TEST_AUDIENCE, jwks=jwks)


def test_wrong_audience_is_rejected(make_token, jwks):
    with pytest.raises(OidcError, match="audience"):
        verify_token(make_token(audience="sigstore"), audience=TEST_AUDIENCE, jwks=jwks)


def test_audience_list_containing_the_value_is_accepted(make_token, jwks):
    token = make_token(extra_claims={"aud": ["something-else", TEST_AUDIENCE]})
    assert verify_token(token, audience=TEST_AUDIENCE, jwks=jwks)["aud"]


def test_wrong_issuer_is_rejected(make_token, jwks):
    token = make_token(extra_claims={"iss": "https://evil.example"})
    with pytest.raises(OidcError, match="issuer"):
        verify_token(token, audience=TEST_AUDIENCE, jwks=jwks)


def test_expired_token_is_rejected(make_token, jwks):
    with pytest.raises(OidcError, match="expired"):
        verify_token(make_token(expires_in=-3600), audience=TEST_AUDIENCE, jwks=jwks)


def test_expiry_inside_the_leeway_is_accepted(make_token, jwks):
    # A runner whose clock drifted by seconds must not fail every deployment.
    verify_token(make_token(expires_in=-30), audience=TEST_AUDIENCE, jwks=jwks)


def test_future_nbf_is_rejected(make_token, jwks):
    token = make_token(extra_claims={"nbf": int(time.time()) + 3600})
    with pytest.raises(OidcError, match="not yet valid"):
        verify_token(token, audience=TEST_AUDIENCE, jwks=jwks)


def test_unknown_kid_is_rejected(make_token, jwks):
    with pytest.raises(OidcError):
        verify_token(make_token(kid="rotated-away"), audience=TEST_AUDIENCE, jwks=jwks)


def test_malformed_token_is_rejected(jwks):
    with pytest.raises(OidcError, match="three-part"):
        verify_token("not-a-jwt", audience=TEST_AUDIENCE, jwks=jwks)


def test_rs256_verify_rejects_a_short_signature():
    assert rs256_verify(2**2047 + 1, 65537, b"payload", b"\x01\x02") is False


def test_authorize_denies_by_default():
    claims = {"repository": "MagmaMoose/website", "repository_owner": "MagmaMoose"}
    with pytest.raises(OidcError, match="not allowed"):
        authorize(claims, frozenset())


def test_authorize_accepts_an_allowed_owner_case_insensitively():
    claims = {"repository": "MagmaMoose/website", "repository_owner": "MagmaMoose"}
    assert authorize(claims, ALLOWED) == "MagmaMoose/website"


def test_authorize_rejects_a_foreign_owner():
    claims = {"repository": "attacker/evil", "repository_owner": "attacker"}
    with pytest.raises(OidcError, match="not allowed"):
        authorize(claims, ALLOWED)


def test_authorize_rejects_disagreeing_claims():
    # A token whose `repository` and `repository_owner` disagree is not something GitHub
    # issues; accepting it would let an allowed owner claim be paired with any repository.
    claims = {"repository": "attacker/evil", "repository_owner": "MagmaMoose"}
    with pytest.raises(OidcError, match="disagree"):
        authorize(claims, ALLOWED)


def test_issuer_is_the_github_one_by_default():
    assert TEST_ISSUER == "https://token.actions.githubusercontent.com"


def test_a_pinned_jwks_document_is_used_instead_of_the_network(signing_key, make_token):
    """A GHES instance the function has no outbound route to, and the LocalStack harness."""
    from tremvok.oidc import JwksCache

    numbers = signing_key.public_key().public_numbers()
    document = json.dumps(
        {
            "keys": [
                {
                    "kty": "RSA",
                    "kid": "test-key-1",
                    "alg": "RS256",
                    "n": b64url(numbers.n.to_bytes((numbers.n.bit_length() + 7) // 8, "big")),
                    "e": b64url(numbers.e.to_bytes((numbers.e.bit_length() + 7) // 8, "big")),
                }
            ]
        }
    )

    def explode(self):  # pragma: no cover - the point is that it is never called
        raise AssertionError("a pinned document must not fall back to the network")

    cache = JwksCache(TEST_ISSUER, loader=lambda: document)
    cache._fetch = explode.__get__(cache)
    assert verify_token(make_token(), audience=TEST_AUDIENCE, jwks=cache)["repository"]


def test_an_unusable_pinned_document_is_an_error_not_a_silent_fallback(make_token):
    from tremvok.oidc import JwksCache

    cache = JwksCache(TEST_ISSUER, loader=lambda: "{not json")
    with pytest.raises(OidcError, match="pinned JWKS"):
        verify_token(make_token(), audience=TEST_AUDIENCE, jwks=cache)
