# Architecture map

## The action (`action.yml` → `scripts/`)

`action.yml` is glue: it maps inputs to environment variables and runs a script. Nothing
decides anything in YAML.

| Step | Script | Job |
|---|---|---|
| resolve | `resolve-mode.sh` | event → `deploy`/`preview`/`rollback`, environment, preview alias |
| preflight | `preflight.sh` | fork or no-credential → an honest **skip** with a reason |
| auth | `assume-role.sh` | OIDC token → STS → masked, short-lived credentials |
| deploy | `deploy-s3-cloudfront.sh` · `deploy-lambda-zip.sh` · `deploy-terragrunt.sh` | the target adapters |
| verify | `verify-live.sh` | curl for status + header, with retries |
| notify | `notify-pr.sh` · `notify-webhook.sh` | sticky PR comment · Slack + Teams |
| record | `record-deployment.sh` | POST to the Tremvok API with an OIDC token |

Terragrunt sub-primitives: `terragrunt-discover.sh` (changed files → stacks),
`terragrunt-run.sh` (plan/apply/redact one stack), `approval-gate.sh` (independent approvers),
`publish-check.sh` (the check run that makes apply-before-merge enforceable).

`scripts/lib/common.sh` holds logging, `set_output` (heredoc form for multi-line),
`is_true`, `slug`, `retry`. Everything sources it.

## The API (`src/tremvok/`)

| Module | Job |
|---|---|
| `api/app.py` | FastAPI factory; `caller_repository` is the auth dependency |
| `oidc.py` | RS256 verification with **no crypto dependency**; `authorize()` is deny-by-default |
| `store.py` | DynamoDB; dedup token written first, compensated on failure |
| `notify.py` | Slack/Teams payloads; every function returns a bool and never raises |
| `models.py` | the wire contract. `repository` is absent by design — it comes from the token |
| `settings.py` | env for config, SSM `SecureString` for secrets |
| `aws/handler.py` | Mangum adapter; `handler` is what Terraform names |

**Why the dependency is module-level.** `api/app.py` uses `from __future__ import annotations`,
so FastAPI resolves annotations against *module* globals. A `Depends` on a closure inside
`create_app` silently degrades to a required query parameter — the auth check vanishes rather
than fails. See COMMON_MISTAKES.

## Infrastructure (`terraform/`)

`modules/tremvok-api` is the whole stack. `localstack/` instantiates the same module with
`localstack = true`, which swaps API Gateway for a Lambda Function URL (payload format 2.0 is
identical, so the code path is not) and skips the alarms.

The cost ceiling is the API Gateway throttle plus Lambda reserved concurrency plus provisioned
DynamoDB — three independent caps, because AWS has no spend cap and Budgets only report.
