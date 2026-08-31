# 2. The API authenticates with GitHub OIDC only, and denies by default

**Status:** accepted · **Date:** 2026-08-19

## Context

The API records deployments and sends notifications. Consumers are workflows in ~9
repositories. The obvious design is an API key per repository, stored as a secret.

## Decision

**GitHub Actions OIDC, and nothing else.** No API key exists.

Two properties follow that a shared secret cannot give:

- **The `repository` a record lands under is the token's claim, not a request field.** Recording
  a deployment against another repository is therefore not *expressible*, rather than rejected
  by a check somebody could forget to write. `DeploymentIn` has `extra: "forbid"`, so sending
  `repository` anyway is a 422.
- **Nothing to rotate or leak.** The token is minted for one run and expires in minutes.

**Deny by default.** GitHub issues an OIDC token to every repository on github.com, so a valid
signature proves only that the caller is *a* GitHub Actions workflow. `allowed_owners` is what
makes it one of ours, and an empty list denies everything — the correct reading of "deployed
without being told who may use it".

**RS256 is verified in-repo, without `cryptography`.** That wheel is ~8 MB, platform-specific,
and would have to be cross-built for the function's architecture; PKCS#1 v1.5 verification is
`pow(sig, e, n)` plus a constant-time compare. This is safe to hand-roll in a way signing would
not be — verification touches no secret, so there is no timing channel — and `tests/test_oidc.py`
covers the ways a JWT verifier is usually wrong (`alg: none`, HS256 with the public key, a
tampered payload, a wrong audience or issuer, an expired token, an unknown `kid`).

## Consequences

**Good.** No secret distribution problem, and the interesting attack is unrepresentable.

**Costly.** A caller that is not a GitHub Actions workflow cannot use the API at all. A
dashboard reading across repositories will need a second credential path, which is why
`GET /v1/deployments` deliberately has no `repository` parameter today.

**Watch.** The hand-rolled verifier is the piece a future contributor will most want to
"simplify" into PyJWT. If that happens, the package grows by an order of magnitude and gains a
cross-build failure mode — see `.claude/COMMON_MISTAKES.md`.
