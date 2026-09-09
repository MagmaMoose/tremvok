# Architecture

Two surfaces, one repository, no shared imports.

```text
GitHub Actions runner
┌────────────────────────────────────────────────────────────┐
│ action.yml (composite, glue only)                          │
│   ├─ validate-inputs.sh   inputs ↔ target, or a hard error  │
│   ├─ resolve-mode.sh      event → deploy | preview          │
│   ├─ preflight.sh         fork / no credential → skip       │
│   ├─ assume-role.sh       OIDC → STS → short-lived creds    │
│   ├─ <target adapter>     docs · s3 · lambda · tg · ansible │
│   ├─ verify-live.sh       curl status + header, retried     │
│   ├─ collect-outcome.sh   one status every sink shares      │
│   ├─ notify-{pr,webhook}.sh                                 │
│   └─ record-deployment.sh ──────────────┐                   │
└─────────────────────────────────────────┼───────────────────┘
                                          │ OIDC-authenticated HTTPS
                                          ▼
                     API Gateway → Lambda (FastAPI + Mangum)
                                          ├─► DynamoDB (90-day TTL)
                                          └─► Slack / Teams
```

## One action, five targets

`target` selects the adapter; everything before and after it is shared. The parts that are
not target-specific — resolving the mode from the event, the honest skip, verification, the
outcome, the three notification sinks — are written once and every target gets them, which
is the argument for one action rather than five.

The cost of a target enum is that a caller can pass an input belonging to a different
target. Silently ignoring it is what would make the Marketplace listing dishonest, so
`validate-inputs.sh` runs first, before the checkout, and refuses the run with every
misplaced input named at once. Applicability comes from `scripts/lib/input-targets.json`,
generated from the input descriptions in `action.yml` — so the page a caller reads and the
check the run performs are built from the same source and cannot disagree.

## Why the action is bash over a thin YAML file

`action.yml` maps inputs to environment variables and runs a script. That is all it does. The
alternative — conditions and string assembly in YAML expressions — cannot be tested, cannot be
run locally, and produces its failures inside a runner. Everything in `scripts/` runs under
`bats` with `aws`, `curl`, `terragrunt` and `ansible-playbook` stubbed, so a test can assert
the exact command line a deploy would have issued, including the flags that only matter when
they are wrong.

Python is used for the things that never run on a caller's runner in the deploy path: the two
generators, the repo-shape linter, the Lambda packager, and the pytest contract suite. Adding
a Python dependency to a target adapter would mean a `setup-python` step on every AWS run, and
put that code outside the bash contract the other 190 tests enforce.

## The one job the action hands back

`actions/deploy-pages` needs `pages: write` and the `github-pages` environment, and a
composite action can declare neither. So `target: docs` with `docs-target: github-pages`
builds and stages the artifact and the caller publishes it. That is the only place an
`environment:` is load-bearing: the Terragrunt apply gate is the action's own logic
(`approval-gate.sh` reads the pull request's reviews), and needs none.

## The guards, and what each one is for

Every one of these is a failure that happened in a hand-rolled `deploy.yml` somewhere in the
fleet.

| Guard | The failure it prevents |
|---|---|
| Refuse to sync an empty artifact directory | a build that quietly produced nothing, plus `sync --delete`, empties the live site — and exits `0` |
| `set -o pipefail` everywhere; never `cmd \| tee` | `tee`'s exit code masked an auth failure and the run "reported success" |
| Verify a **header**, not just a `200` | a deploy that uploads but does not bind: the old version keeps serving and everything looks green |
| Immutable artifact keys | overwriting a published key changes the code behind a version somebody already reviewed |
| Compare the deployed `CodeSha256` | "the API accepted my request" is not "the function runs my code" |
| A preview never moves the alias | a pull request proving a package deploys must not change what production serves |
| `workflow_dispatch` pinned to the default branch | "Run workflow" from a topic branch publishes it to production, and looks like a normal deploy |
| An input that belongs to another target is an error | a caller passing `s3-bucket` to `target: ansible` gets a mistake reported, not a run that quietly ignores half its configuration |
| Terragrunt applies the **saved** plan | re-planning at apply time means what lands is a plan resembling the reviewed one, not the reviewed one |
| Ansible re-runs in check mode | a zero exit proves the playbook ran; only a second run finding nothing left to change proves it converged |
| A pinned, checksum-verified tofu/terragrunt | the binary that applies to production is the one input nobody reviews when it floats |
| Publish the check run even with **zero** stacks | a required check that never reports blocks the pull request forever |
| An unreadable review list is an error, not "nobody approved" | the difference between "wait for approval" and "apply without one" |
| Honest skips for forks and unwired repositories | an expected policy outcome presenting as a broken credential |
| Failure-isolated sinks | a chat outage failing a successful deploy, inviting a re-run that deploys again |

## The target adapter boundary

`target` selects a script. The resolve → deploy → verify → notify → record skeleton is
target-agnostic, so a new target is one script, one gated step, and one bats file. The three
that exist are S3/CloudFront, Lambda packages and Terragrunt; Kubernetes deploy *status* and
the GitHub Deployments API slot in behind the same interface without touching the skeleton.

## The API, and why it is not just webhooks

v1 of the design had no backend: Slack and Teams are incoming webhooks, and the pull-request
comment uses `GITHUB_TOKEN`. That still works — leave `api-url` empty and nothing calls the
service.

The backend earns its place when you want either of two things:

**Notifications without a secret in every repository.** With the API, the Slack and Teams URLs
live in one Parameter Store entry that the Lambda reads. A consumer repository holds no
credential at all: it authenticates with a GitHub OIDC token minted for that run, expiring in
minutes, carrying a `repository` claim it cannot forge.

**Deployment history.** "When did production last change, and to what?" is not answerable from
workflow logs that expire, and it is the question every incident starts with.

The security model is the interesting part, and it is deliberately narrow: the `repository` a
record lands under is the token's claim rather than a request field, so recording a deployment
against someone else's repository is not *expressible*. And because GitHub issues an OIDC token
to every repository on github.com, a valid signature alone proves only that the caller is *a*
workflow — `allowed_owners` is what makes it one of ours, and an empty list denies everything.

## Idempotency

The action derives a `delivery_id` of `<run_id>:<attempt>:<environment>:<mode>`. A retried
notify step inside the same attempt is the same delivery; a re-run of the job is a new one. The
API takes an idempotency token in DynamoDB with a conditional put **before** writing the record,
and deletes the token again if the record write fails — so a failed record is retryable rather
than permanently swallowed by its own dedup marker.

The property this buys is that **notifications are exactly-once**. Duplicate history rows would
be cosmetic; a second Slack ping for the same deploy is the thing humans actually notice.

## Why the OIDC verifier has no dependencies

The obvious implementation is PyJWT, which needs `cryptography`: an 8 MB platform-specific
wheel that has to be cross-built for the Lambda's architecture and would dominate the package.
Verifying an RSA PKCS#1 v1.5 signature is `pow(sig, e, n)` and a constant-time compare against a
fixed prefix — thirty lines of integer arithmetic.

This is safe to hand-roll in a way that *signing* would not be: verification touches no secret,
so there is no timing channel, and the comparison is `hmac.compare_digest` regardless.
`tests/test_oidc.py` signs real tokens with `cryptography` (a dev dependency) and checks that
`alg: none`, HS256-with-the-public-key, a tampered payload, a wrong audience, a wrong issuer and
an expired token are all rejected.
