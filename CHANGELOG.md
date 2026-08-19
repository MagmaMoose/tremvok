# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Composite action** (`action.yml`) with three AWS target adapters:
  - `s3-cloudfront` — sync a built static site with per-class cache headers, invalidate
    CloudFront, previews under their own key prefix. Refuses to sync an empty artifact
    directory.
  - `lambda-zip` — immutable S3 keys, published versions, alias moved only on a deploy, and the
    deployed `CodeSha256` verified against the local artifact.
  - `terragrunt` — discover, plan, gate on an independent approval, apply; rolling pull-request
    comment with redacted plan excerpts and a check run that makes apply-before-merge
    enforceable. Replaces Atlantis and its stored IAM credential.
- **Post-deploy verification** (`verify-url`, `verify-header`, `verify-header-match`) with
  retries, catching the deploy that uploaded but did not bind.
- **Notifications**: sticky pull-request comment, Slack and Microsoft Teams incoming webhooks,
  each optional and failure-isolated.
- **OIDC role assumption** (`assume-role.sh`), so no repository stores an AWS key.
- **Honest skips** for fork pull requests and repositories with no credential configured.
- **The Tremvok API** (`src/tremvok/`): FastAPI + Mangum on Lambda, recording deployment
  history in DynamoDB and fanning notifications out. Authenticated by GitHub Actions OIDC with
  a deny-by-default owner allowlist; the `repository` a record lands under is the token's claim.
- **RS256 verification with no crypto dependency** (`oidc.py`), keeping the Lambda package
  small and architecture-portable, with an optional pinned JWKS in Parameter Store for
  egress-restricted or Enterprise Server deployments.
- **Terraform module** (`terraform/modules/tremvok-api`) capped three independent ways —
  API Gateway throttle, Lambda reserved concurrency, provisioned DynamoDB — because AWS has no
  spend cap.
- **LocalStack harness** (`make -C terraform dev`) proving the whole stack without an AWS
  account.
- Tests: 126 `bats` cases over the shell scripts, 90 `pytest` cases over the API, and an
  end-to-end smoke suite against LocalStack.

[Unreleased]: https://github.com/MagmaMoose/tremvok/commits/main
