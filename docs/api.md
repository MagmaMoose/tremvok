# API reference

Optional. Leave the action's `api-url` empty and nothing here is called.

Base URL: whatever `terraform output api_url` reports — an API Gateway HTTP API endpoint in
production, a Lambda Function URL under LocalStack.

## Authentication

A **GitHub Actions OIDC token**, and nothing else. There is no API key to mint, store, rotate or
leak.

```http
authorization: Bearer <token minted for audience "tremvok">
```

The action does this for you (`record-deployment.sh`); a workflow only needs
`permissions: id-token: write`.

Verification, in order:

1. `alg` must be `RS256`. `none` and the HMAC algorithms are rejected before any signature work
   — with HS256, anyone holding the public key can sign their own token with it.
2. The signature must verify against the issuer's JWKS (fetched and cached per execution
   environment, refetched on an unknown `kid` so key rotation is a non-event).
3. `iss` must be a configured issuer, `aud` must match, `exp`/`nbf` must be current within 60
   seconds of clock skew.
4. `repository_owner` must be in `allowed_owners`, and must agree with `repository`.

**Step 4 is the one that matters.** GitHub issues an OIDC token to every repository on
github.com, so steps 1–3 prove only that the caller is *a* GitHub Actions workflow. An empty
`allowed_owners` denies everything, which is the correct reading of "deployed without being told
who may use it".

### Pinned keys

Set `<parameter-prefix>/jwks-document` to a JWKS and the function verifies against it without
any outbound call to the issuer. That is how a GitHub Enterprise Server deployment behind
restricted egress works — and how the LocalStack harness has an issuer at all.

## Endpoints

### `GET /healthz`

No auth, no storage read. A health check that reads DynamoDB turns a throttled table into an
unhealthy service; this endpoint's only job is to say the function is warm and the package
imported — which, given a compiled `pydantic-core`, is a genuinely useful thing to know.

```json
{"status": "ok", "service": "tremvok", "version": "0.1.0"}
```

### `POST /v1/deployments`

```json
{
  "delivery_id": "18234:1:production:deploy",
  "environment": "production",
  "status": "success",
  "target": "s3-cloudfront",
  "mode": "deploy",
  "version": "1.4.0",
  "url": "https://magmamoose.com/",
  "commit": "0123456789abcdef",
  "run_url": "https://github.com/MagmaMoose/website/actions/runs/18234",
  "actor": "CalebSargeant",
  "verified": true,
  "duration_ms": 41200
}
```

`repository` is **not** a field. It comes from the token, which is what makes recording against
another repository inexpressible rather than merely rejected. `extra: "forbid"` means sending it
anyway is a `422`, not a silent drop.

`status` is one of `success`, `failure`, `skipped`, `rolled-back`. `target` is one of
`s3-cloudfront`, `lambda-zip`, `terragrunt`, `other`. `url` and `run_url` must be `http(s)` —
a notification renders them as links, and a `javascript:` URL in a chat card is a phishing
primitive.

Response:

```json
{"deployment_id": "9f2c…", "repository": "MagmaMoose/website",
 "recorded_at": "2026-08-19T07:41:22.104Z", "duplicate": false,
 "notified": {"slack": true}}
```

A repeat of the same `delivery_id` returns `200` with `duplicate: true` and sends nothing. It is
deliberately **not** a `409`: the caller retried a notify step, which is correct behaviour, and
a 4xx there would fail a job whose deploy succeeded.

`notified` omits sinks that are not configured, and reports `false` for a sink that failed —
which never fails the request.

### `GET /v1/deployments?environment=&limit=`

The calling repository's history, newest first. There is no `repository` parameter: you read
your own. Cross-repository reads are a dashboard feature and want a different credential than a
workflow token.

## Storage

One DynamoDB table, one partition per repository:

```text
pk = repo#<owner>/<name>   sk = dep#<recorded_at>#<deployment_id>   the record
pk = repo#<owner>/<name>   sk = dedup#<delivery_id>                 the idempotency token
```

Both carry `expires_at`, so nothing survives the retention window. Capacity is **provisioned**,
not on-demand: on-demand cannot be capped, and a table that can scale itself has no cost
ceiling.
