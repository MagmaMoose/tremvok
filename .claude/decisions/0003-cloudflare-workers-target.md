# 3. Cloudflare Workers is a deployment target; Tremvok's own hosted components stay AWS

**Status:** accepted · **Date:** 2026-09-09 ·
**Supersedes:** [0001 — AWS free tier, not Cloudflare](0001-aws-not-cloudflare.md), in part ·
**Context:** [agent-personal#9](https://github.com/CalebSargeant/agent-personal/issues/9)

## Context

0001 was answering two questions at once, and neither of them was about deploy destinations.

The questions it actually reasoned about were **where Tremvok's own backend runs** — FastAPI on
Lambda, not a Worker — and **what the cost discipline is** — the AWS always-free allowances,
with the two exceptions costed rather than rounded away. Both are about infrastructure Tremvok
itself runs and pays for.

It then wrote the conclusion as "AWS for **every target** and every hosted component". That
phrasing swept in deploy destinations, which is a different thing entirely: somewhere a caller
asks Tremvok to publish *their* code on *their* account.

The contradiction shipped immediately and lasted. The root `action.yml` carried Cloudflare Pages
support from `v1.0.0` through `v1.0.20` — `cloudflare-api-token`, `docs-require-access`,
`access_covers.py`, `deploy-cloudflare-pages.sh`, and two steps in the `runs` block. For twenty
releases the rule said one thing and the code did another, and nothing noticed: no test, no
lint, no review. A hard constraint that nothing enforces is a comment.

The Nievah review on PR #20 was the first thing to enforce it, and the contradiction was
resolved in the direction of the rule: commit `a2e9f57` deleted the whole Cloudflare Pages path.

0001's own Consequences section had already named the price and accepted it:

> The fleet's existing products deploy to Cloudflare Workers, so Tremvok cannot deploy them
> until either they move or a Workers adapter is added. The target-adapter boundary is
> deliberately shaped so that adding one later is a script and a gated step, not a redesign —
> but "no Cloudflare" means it will not be added here.

That is the sentence this ADR reverses. Everything in it was right except the last clause: the
boundary was shaped correctly, the adapter *is* a script and a gated step, and the fleet's
products still deploy to Workers.

## Decision

**Cloudflare Workers is a deployment target.** `target: cloudflare-workers`,
`scripts/deploy-cloudflare-workers.sh`, and thirteen `cloudflare-*` inputs. `mode: deploy` runs
`wrangler deploy`; `mode: preview` runs `wrangler versions upload --preview-alias pr-<N>`, which
publishes a version on its own URL that takes no production traffic.

**The distinction 0001 blurred, stated plainly:**

- a **hosted component** is infrastructure Tremvok itself runs and pays for — Lambda, DynamoDB,
  API Gateway, the artifact bucket;
- a **target** is somewhere a caller asks Tremvok to deploy *their* code, on *their* account,
  with *their* credentials.

0001's rule was right about the first and wrong to generalise it to the second. Tremvok choosing
a provider for its own backend is an architectural decision with a bill attached. A caller
choosing where their product runs is not Tremvok's decision to make.

**What 0001 still holds, restated here as binding:**

- **Tremvok's own hosted components stay AWS.** The API is Python FastAPI on Lambda, not a
  Worker, and it stays optional: leave `api-url` empty and nothing calls it. Nothing in 0001's
  Decision about the backend changes.
- **The free-tier cost discipline is unchanged.** The API Gateway throttle, Lambda reserved
  concurrency and provisioned DynamoDB are still three independent caps, still in code rather
  than in an alarm that notices afterwards.
- **A Cloudflare Workers deploy costs Tremvok nothing.** It runs `npx wrangler` on the caller's
  runner, against the caller's account, with the `cloudflare-api-token` and
  `cloudflare-account-id` the caller supplies. There is no Tremvok-side Cloudflare account,
  resource or bill, so the cost ceiling is untouched.
- **Nothing new is applied to a real account by this change.** As in 0001, LocalStack is the
  only environment; the adapter is covered by bats with a recorder in front of Wrangler
  (`WRANGLER_BIN`), never a live call.

**Wrangler is pinned.** `cloudflare-wrangler-version` defaults to `4.114.0`, because the tool
that publishes to production is not a floating dependency. The flags used are verified against
that version's `--help`, and only `versions upload` takes `--preview-alias`.

## Consequences

**Good.** The fleet's existing products can be deployed by Tremvok without moving off Workers
first — exactly the thing 0001 gave up. `mode: preview` gets a real destination on this target: a
pull request publishes a version on `pr-<N>`, a genuine preview URL. That is worth contrasting
with `github-pages`, which has one site and no preview destination at all, so a pull request
there builds and checks without staging — which is why `docs-target` was removed rather than
renamed. And the rule in CLAUDE.md now matches the code, so the next reviewer who reads "no
Cloudflare" and the next engineer who reads `action.yml` are looking at the same repository.

**Costly.** Three prices, none theoretical:

- **A second cloud provider in the action's surface.** Every target is a support obligation.
  This one brings its own auth model, its own outages and its own release cadence into an
  action whose other four targets are all AWS.
- **One more credential shape to document.** The AWS targets use OIDC role assumption and hold
  no stored secret — 0001 counted that as a win, correctly. Cloudflare has no OIDC path here, so
  `cloudflare-api-token` is a stored, long-lived secret in the caller's repository. That is a
  strictly weaker credential than the rest of the action uses, and the docs have to say so
  rather than presenting the targets as equivalent.
- **Wrangler as a pinned tool dependency.** A pin is a version somebody has to bump, and it has
  a second edge: Wrangler 4 declares `engines.node >= 22`, installs cleanly on 20 and then
  refuses to run, which is why `cloudflare-node-version` exists and defaults to `24` instead of
  trusting whatever the runner ships.

**Deferred.** Cloudflare Access — `require-access` and `access_covers.py` — went with the Pages
path in `a2e9f57` and is **not** restored here. Whether a preview URL should sit behind Access
is a separate question from whether Tremvok can publish one, and it deserves its own decision
rather than arriving as a leftover. Separately, the adapter parses Wrangler's stdout for the URL
and version id, because a preview URL is per-alias and a deploy URL comes from the config's
routes, so neither can be constructed without duplicating the config. If Wrangler grows a
machine-readable output for those, the parsing should go.
