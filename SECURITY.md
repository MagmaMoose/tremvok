# Security policy

## Reporting a vulnerability

Open a private security advisory on
[MagmaMoose/tremvok](https://github.com/MagmaMoose/tremvok/security/advisories/new), or email
`caleb@magmamoose.com`. Please do not open a public issue for a vulnerability.

## The security model, stated plainly

Tremvok runs inside other people's deployment pipelines and holds credentials to production, so
it is worth being explicit about what protects what.

### The action

- **No stored AWS credential.** `assume-role.sh` exchanges this run's GitHub OIDC token for an
  STS session that expires in an hour. The role's *trust policy* is the control — scope it to
  the repository **and** the refs allowed to deploy. `repo:owner/name:*` lets any branch in
  that repository assume the role; `repo:owner/name:ref:refs/heads/main` does not.
- **Credentials are masked before export.** `::add-mask::` is emitted for the secret key and
  session token before they reach `GITHUB_ENV`, so a later step that dumps its environment
  cannot print them into a log.
- **Fork pull requests skip.** A fork cannot read secrets. `allow-fork-preview` exists, is off,
  and should stay off.
- **Manual runs are pinned to the default branch**, so "Run workflow" from a topic branch
  cannot publish it to production.
- **Plan output is redacted** before it reaches a pull-request comment: credential-shaped
  assignments, AWS access key ids, and URL userinfo.

### The API

- **GitHub Actions OIDC only.** There is no API key anywhere. The `repository` a record lands
  under is the token's claim, so recording against another repository is not expressible.
- **Deny by default.** GitHub issues an OIDC token to *every* repository on github.com. A valid
  signature proves only that the caller is a GitHub Actions workflow; `allowed_owners` is what
  makes it one of ours, and an empty list denies everything.
- **`alg` is pinned to RS256.** `none` and the HMAC algorithms are refused before any signature
  work — with HS256, anyone holding the public key can sign their own token with it.
- **Secrets are SSM `SecureString`**, never Lambda environment variables (plaintext to anyone
  with `lambda:GetFunctionConfiguration`) and never Terraform resources (a secret in state).
- **URLs in a record must be `http(s)`.** They are rendered as links in Slack and Teams, and a
  `javascript:` URL in a chat card is a phishing primitive.
- **The IAM role can read and write its own table, read its own parameters, and write its own
  logs.** It cannot spend money.

### A hand-rolled signature verifier

`src/tremvok/oidc.py` implements RSA PKCS#1 v1.5 verification rather than depending on
`cryptography`. This is a deliberate, bounded choice: **verification touches no secret**, so
there is no timing channel to leak through, and the comparison is `hmac.compare_digest`
regardless. The alternative was an 8 MB platform-specific wheel that has to be cross-built for
the function's architecture.

`tests/test_oidc.py` is the reason to trust it: it signs real tokens and asserts that a tampered
payload, an unsigned token, `alg: none`, HS256, a wrong audience, a wrong issuer, an expired
token and an unknown `kid` are each rejected.

## Supported versions

The floating `v1` major tag receives fixes. Pin to a SHA if you need immutability.
