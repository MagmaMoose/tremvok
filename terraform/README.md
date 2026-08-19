# The Tremvok API infrastructure

One Lambda behind one HTTP API, one DynamoDB table, and the controls that keep the whole thing
free. The **code** lives in `src/tremvok/`; this owns the infrastructure and points at a
published artifact.

```
GitHub Actions ──► API Gateway ──► tremvok-api ──┬──► DynamoDB  (90-day TTL)
   OIDC token       HTTP API        FastAPI      │
   no stored        2 req/s         + Mangum     ├──► SSM       (webhook URLs)
   credential       throttle                     │
                                                 └──► Slack / Teams webhooks
```

| | |
|---|---|
| `modules/tremvok-api` | the whole stack: table, function, API, IAM, logs, alarms |
| `localstack/` | a root that instantiates the module against LocalStack, plus `harness.sh` — the one definition of the local sequence, which CI runs too |
| `Makefile` | `make dev` — up, build, apply, smoke |

## What it costs

AWS says "free tier" for two offers that behave nothing alike:

| | what it is | when it ends |
|---|---|---|
| **Always Free** | a permanent monthly allowance that resets | **never** |
| **12-Month Free** | only the account's first year | silently, at month 13 |

Measured against a realistic ceiling of **200 deployments a month** across the whole fleet:

| service | free, per month | this stack uses | headroom |
|---|---|---|---|
| Lambda | 1M requests, 400,000 GB-s | ~600 requests, ~90 GB-s | ~4,000× |
| DynamoDB | 25 GB, 25 WCU, 25 RCU | a rolling 90 days of records, 2 WCU | 12× |
| CloudWatch | 10 alarms, 5 GB logs | 2 alarms, 14-day retention | — |
| SSM Parameter Store | 10,000 standard params | 2 | — |
| SNS | 1M publishes | a handful of alarms | — |
| **S3** (artifacts) | **5 GB — 12-MONTH** | ~3 MB per release, kept | ~$0.0001/mo |
| **API Gateway** (HTTP API) | **1M req — 12-MONTH** | ~600 requests | ~$0.0006/mo |

**Two things here are not always-free: API Gateway and the artifact bucket.** Together, well
under a cent a month at real traffic. Called out rather than rounded away, because the brief
for this stack was "free".

### The cost ceiling, and why it is not just an alarm

AWS has **no spend cap**. Budgets report; they do not stop, and they can lag hours. So the real
control is enforced in real time, at the door:

| control | value | what it bounds |
|---|---|---|
| API Gateway throttle | **2 req/s, burst 10** | the request rate. Over-limit requests get a 429 at the gateway and never become an invocation |
| Lambda reserved concurrency | **5** | how many invocations can ever run at once — redundant with the throttle on purpose, because the throttle only protects the front door |
| DynamoDB | **provisioned 2/2**, not on-demand | on-demand cannot be capped; provisioned throttles instead, and a throttled record is a retry |
| DynamoDB TTL | 90 days | history cannot accumulate |
| CloudWatch Logs | 14-day retention | log storage cannot accumulate |

**The worst case, stated honestly.** Someone who finds the URL and floods it at the full
throttle, 24/7, unnoticed for a whole month: roughly **$5 of API Gateway and under $1 of
Lambda**. It cannot touch DynamoDB at all — an unauthenticated request is refused **401 before
anything is written**, so no storage is reachable without a valid GitHub OIDC token for an
allowed owner.

**Deliberately no `aws_budgets_budget` here.** Two budgets are free per account and every one
after that is **$0.02/day** — a third budget would itself be the surprise bill. Budgets belong
to the account, not to this stack; `MagmaMoose/infra`'s `cost-report` leaf already owns them
and reports daily spend and free-tier headroom to Slack.

### Why there is no CDN in front of the API

[caldrith#68 / chargate#54](https://github.com/MagmaMoose/caldrith/issues/68) argues for putting
Cloudflare in front of an API Gateway front door so abusive volume is absorbed at a free edge
instead of being metered by AWS. It is a good argument for nievah's front door, which takes
~950 GitHub deliveries a day from the public internet.

It is **not** taken here, for three reasons:

1. **No Cloudflare, by decision.** Everything Tremvok needs is AWS.
2. **The traffic is nothing like nievah's.** This endpoint is called a few times a day, by
   workflows, and every request that is not a valid OIDC token for an allowed owner is refused
   `401`/`403` before anything is written. There is no expensive work behind the door to protect.
3. **That issue's own conclusion applies regardless.** It ends with *"keep the API Gateway
   throttle sized as though Cloudflare were not there — it is the only control that still holds
   when someone finds the origin."* That is exactly what the 2 req/s throttle is, and it is
   sized without assuming anything in front of it.

The one piece of that issue that would apply — `disable_execute_api_endpoint = true` — is
deliberately **not** set, because there is no custom domain here: the `execute-api` endpoint is
the front door, and disabling it would close the only one there is. Add a custom domain and it
should be set in the same change.

### Secrets

**SSM Parameter Store `SecureString`, never Secrets Manager, never environment variables.**

* A Lambda environment variable is plaintext to anyone holding
  `lambda:GetFunctionConfiguration`, which is a much wider audience than it looks.
* Secrets Manager's $0.40/secret/month buys automatic rotation, and an incoming-webhook URL
  rotates approximately never.

Terraform deliberately does not create them — a secret in a Terraform resource is a secret in
Terraform state:

```bash
aws ssm put-parameter --name /tremvok/prod/slack-webhook --type SecureString --value "https://hooks.slack.com/…"
aws ssm put-parameter --name /tremvok/prod/teams-webhook --type SecureString --value "https://…"
```

There is a third, optional parameter: `/tremvok/prod/jwks-document`. Set it to a pinned JWKS
and the function verifies tokens without an outbound call to the issuer at all — which is how a
GitHub Enterprise Server deployment behind restricted egress works, and how the LocalStack
harness has an issuer to verify against.

## Local development

```bash
make -C terraform dev
```

`up` + `api-zip` + `apply-local` + `smoke`: starts LocalStack, builds the Lambda package with
**this repository's own script** (never a copy — a local run and a released artifact built
differently is a difference nobody finds until production), applies the real module, and
asserts the invariants end to end — a signed token recorded once, an unsigned one refused, a
foreign owner refused, a retry deduplicated, a failing notification sink not failing the
request, and the action's own deploy scripts run against a real S3 and a real Lambda.

### What a local run does NOT prove

* **API Gateway is LocalStack Pro-only.** Locally the front door is a Lambda Function URL. The
  substitution is honest rather than lossy — HTTP API payload format 2.0 is byte-for-byte the
  event a Function URL delivers, so the handler and everything downstream are the identical
  code path — but the gateway's OWN configuration (**the throttle**, the `$default` stage, the
  integration) is never exercised. The throttle is the cost ceiling, so **verify it against the
  real thing after the first apply**, and verify with a real signed `POST` rather than a `GET`:
  a health check passing proves almost nothing about the write path.
* **CloudWatch alarms are accepted and never evaluated**, so none are created locally.

### The architecture trap

`pydantic-core` is a compiled wheel. A package built on an Apple Silicon laptop and deployed to
an `x86_64` function imports fine locally and dies at the first request with
`No module named 'pydantic_core._pydantic_core'` — after a clean apply and a green plan. The
Makefile derives `ARCH` from `uname -m` and passes it to both the builder and the module for
exactly this reason. In production, `architecture` and the CI build flag must agree.

## Cold start

There is a real chicken-and-egg on the first run: the function points at
`api/<version>.zip`, which does not exist until CI publishes it.

```bash
# 1. The artifact bucket and the GitHub OIDC publish role live in MagmaMoose/infra
#    (terraform/aws/modules/artifacts) — this module consumes a bucket, it does not create one.

# 2. Secrets, by hand. See above.

# 3. Publish once, then point the leaf at what it made.
cd terraform/prod/eu-west-1/tremvok-api && terragrunt apply

# 4. Prove it is up. MUST be 200 — and then prove the WRITE path with a signed POST.
curl -si "$(terragrunt output -raw healthz_url)" | head -1
```

## Promotion to `MagmaMoose/infra`

This module lives here today because Tremvok has no AWS account yet and everything must be
provable on LocalStack. The house pattern — the one nievah's front door follows — is that the
**code repository owns the code and the packaging contract, and `infra` owns the deployment**.

When an account exists, `modules/tremvok-api` moves to `infra/terraform/aws/modules/` and a
leaf appears at `infra/terraform/aws/prod/eu-west-1/tremvok-api/`, where bumping
`artifact_version` *is* the deployment and is a reviewed pull request. `localstack/` stays
here, because what it tests is this repository's own wiring.

That leaf should be one of the first things Tremvok's own `terragrunt` target deploys — which
is the point at which the Atlantis credential can be deleted.
