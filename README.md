# Tremvok

Deployment orchestration + notifications for MagmaMoose — the deploy-side
counterpart to [Diatreme](https://github.com/MagmaMoose/diatreme). One
composite action that takes an already-built artifact, ships it to a target
(Cloudflare Workers first), verifies it actually went live, and announces the
result to humans (sticky PR comment + Slack + Teams).

Diatreme decides *what version and whether it's released*. Tremvok gets it
*live and tells everyone*.

> **Status: name reserved, nothing built.**
> Scoping lives in `knowledge/magmamoose-tremvok/PROPOSAL.md` in
> [agent-personal#8](https://github.com/CalebSargeant/agent-personal/pull/8),
> tracked by [agent-personal#9](https://github.com/CalebSargeant/agent-personal/issues/9).

Accent gemstone: **peridot**.
