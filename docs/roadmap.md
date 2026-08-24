# Roadmap

<!-- sources: README.md -->

Tremvok's scope is **deployment orchestration and notification** — the deploy-side
counterpart to [Diatreme](https://github.com/MagmaMoose/diatreme). Docs deploy is the
first target because it is the one with a real consumer today: five MagmaMoose repos
carried a complete MkDocs site that nothing published.

Everything below is scoped, not built. Status here is the single source; if a claim
about maturity appears anywhere else in this repo, it is wrong.

## Shipped

- **Docs deploy** — detect toolchain, build strictly, publish to GitHub Pages, verify
  the published URL answers.

## Next

- **Cloudflare Pages as a deploy target.** GitHub Pages cannot gate a published site
  behind auth below the Enterprise Cloud plan — a Pages site built from a *private* repo
  is still served on the open internet. Cloudflare Pages plus Access is the route to
  gated docs for a private or licensed product.
- **A notification surface.** A sticky pull-request comment saying what deployed, where,
  and whether verification passed; Slack and Teams after that.

## Not planned yet

- **Non-docs artifacts.** The action is deliberately narrow: one job, described
  accurately by one Marketplace listing. A `job:` enum where most values error is a
  listing that cannot say what it does. Additional targets get their own entry point
  rather than a mode flag on this one.
- **Rollback.** Verification tells you a deploy did not serve. Deciding what to do about
  it is a different problem and needs deploy history to be worth anything.
