# Roadmap

<!-- sources: README.md, action.yml -->

Tremvok's scope is **deployment orchestration and notification**: the deploy-side
counterpart to [Diatreme](https://github.com/MagmaMoose/diatreme). One action covering
several deployment targets, not a family of narrow ones.

Status here is the single source; if a claim about maturity appears anywhere else in this
repo, it is wrong.

## Shipped

- **`target: docs`**: detect the toolchain, build strictly, publish to GitHub Pages or
  Cloudflare Pages, verify the published URL answers.
- **`target: s3-cloudfront`**: sync a built static site with per-class cache headers,
  invalidate CloudFront, previews under their own key prefix. Refuses to sync an empty
  artifact directory.
- **`target: lambda-zip`**: immutable S3 keys, published versions, the alias moved only on
  a deploy, and the deployed `CodeSha256` verified against the local artifact.
- **`target: terragrunt`**: discover, plan, gate on an independent approval, apply; a
  rolling pull-request comment with redacted plan excerpts, and a check run that makes
  apply-before-merge enforceable. Replaces Atlantis and its stored IAM credential.
- **`target: ansible`**: pinned Ansible, galaxy requirements, a playbook run over SSH with
  keys that cannot reach a log, check mode by default on a pull request, and a second
  check-mode run that proves the playbook converged.
- **Post-deploy verification**, **notifications** (sticky pull-request comment, Slack,
  Teams), and the **deployment-record API**.

## The entry-point rule, reversed

This page used to say that additional targets would get their own entry point rather than a
mode flag, because "a `job:` enum where most values error is a listing that cannot say what
it does". **That position is reversed**, and one action now carries every target.

The objection was right about the failure mode and wrong about the cause. A target enum
becomes a listing that cannot describe itself when the inputs that do not apply to the
selected target are *silently ignored*. The listing then documents an input surface that
does nothing for most callers. So the build removes the silence:

- **Every input is validated against the selected target.** An input that does not apply is
  a hard error naming the target, raised before the checkout. `target: ansible` with
  `s3-bucket` set is a mistake, and it is reported as one, with every other mistake in the
  same run.
- **Applicability is derived, not maintained.** `scripts/gen_input_targets.py` reads it out
  of the input descriptions in `action.yml` into the map the runtime validator uses, so the
  documentation and the check cannot disagree.
- **Input names carry their target**: `docs-`, `s3-`, `cloudfront-`, `lambda-`,
  `terragrunt-`, `ansible-`, with `aws-` for what the AWS targets share and no prefix for
  what everything shares.

What the split cost was worse than what it bought: three entry points meant three
Marketplace-facing surfaces, an `examples/` directory pointing at the wrong one, and a
README, a roadmap and a repository description that each described a different product.

## Next

- **Rollback as a first-class mode.** `mode: rollback` resolves today but no target
  implements re-publishing a previous version. Deployment history exists to make it
  possible; wiring it is the remaining work.
- **A second non-AWS target.** Nothing in the action's shape is AWS-specific: `docs` and
  `ansible` already are not, and the validated-input design is what makes adding one cheap.

## Not planned

- **Building your app.** The build is legitimately per-product. Tremvok picks up at "the
  artifact exists".
- **Reconciling GitOps.** Where a service is deployed by a cluster-side reconciler,
  Tremvok's job is to report and verify, not to apply.
