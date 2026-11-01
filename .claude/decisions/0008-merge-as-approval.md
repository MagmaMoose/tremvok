# 8. A merge can be the approval, when nobody else can give one

**Status:** accepted · **Date:** 2026-11-01

## Context

`terragrunt-apply-on-merge` applies a merged pull request only when someone other than its author
approved it. A repository with one maintainer can never meet that, so every merge plans and applies
nothing. Required reviewers on an environment are no way round it: on a private repository they need
GitHub Enterprise.

## Options considered

**A. Have such a caller dispatch every apply with `terragrunt-apply: force`.** Safe, but each change
takes two steps, and applies get skipped.

**B. Let such a caller keep its own pipeline.** It copies discovery, comments, saved plans and the
credential checks, and misses every fix made here.

**C. An explicit value of `terragrunt-apply-on-merge`, with limits on what such a merge can reach.**
Chosen.

## Decision

`without-approval` makes the merge the approval. It names what it gives up, so a reader of the
workflow sees it, and `true` keeps meaning an independent approval. A direct push still applies
nothing, and a lookup that can't say which pull request merged fails rather than guessing.

Three inputs limit it. Each is off by default and works on its own:

- `terragrunt-scope: direct` plans only the stacks a change touched, so merging a shared file can't
  apply whatever is pending in stacks nobody reviewed by name.
- `terragrunt-hold-destroys` stops the run when a plan destroys or replaces anything, including the
  re-plan of a stale saved plan.
- `terragrunt-stacks` with `terragrunt-apply: force` is how someone who read a held plan applies it.

## Consequences

- Anyone who can merge can apply alone. That trade is the caller's to make, and no default offers it.
- The hold reads tofu's `Plan:` summary line, so a tofu version that rewords it could let a destroy
  through. Check that line when bumping the default tofu version.
