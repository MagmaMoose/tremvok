# 1. AWS free tier, not Cloudflare, for every target and every hosted component

**Status:** accepted · **Date:** 2026-08-19 ·
**Context:** [agent-personal#9](https://github.com/CalebSargeant/agent-personal/issues/9)

## Context

The proposal scoped `target: cloudflare-workers` as the MVP, because that is where the fleet
lives, and put S3/CloudFront on the roadmap. It also deferred any backend, noting that a
Cloudflare Worker would be the natural home if one were ever justified.

Two things changed that:

1. **There is no Cloudflare in this design's future.** The requirement is AWS for anything
   Tremvok needs, and the sibling AWS work already exists — nievah's front door
   ([infra#638](https://github.com/MagmaMoose/infra/pull/638)) establishes the free-tier
   pattern, the LocalStack harness, and the cost accounting this follows.
2. **The most valuable thing to deploy is the thing that has no deployer.** infra's own AWS
   leaves are applied by Atlantis, which needs a *stored* IAM credential able to create roles
   and policies. That credential is the strongest single argument for moving deployment into
   GitHub Actions, and it is not a Cloudflare problem at all.

## Decision

- **v1 targets are `s3-cloudfront`, `lambda-zip` and `terragrunt`.** No Cloudflare adapter.
- **The backend exists, and it is Python FastAPI on Lambda**, not a Worker. It is optional:
  leave `api-url` empty and nothing calls it.
- **Everything sits inside the AWS always-free allowances**, with the two exceptions (API
  Gateway and the artifact bucket) costed explicitly rather than rounded away.
- **Nothing is applied to a real account yet.** LocalStack is the only environment, and the
  harness is what proves the wiring.

## Consequences

**Good.** The action's OIDC role assumption removes a stored credential rather than scoping
one. The FastAPI service can be imported by the same tests that cover the rest of the Python,
which a Worker could not. The free-tier discipline is enforced in code — an API Gateway
throttle, Lambda reserved concurrency, and provisioned DynamoDB — rather than by an alarm that
notices after the fact, because AWS has no spend cap.

**Costly.** The fleet's existing products deploy to Cloudflare Workers, so Tremvok cannot
deploy them until either they move or a Workers adapter is added. The target-adapter boundary
is deliberately shaped so that adding one later is a script and a gated step, not a redesign —
but "no Cloudflare" means it will not be added here.

**Deferred.** `terraform/modules/tremvok-api` lives in this repository, which breaks the house
pattern of `infra` owning deployment. That is a consequence of having no AWS account: there is
no leaf to write. The promotion path is documented in `terraform/README.md` and should happen
in the same change that gives Tremvok an account.
