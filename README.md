# PeerBench Node Deploy

Deployment scripts for running your own PeerBench federation node.

## Quick start

```bash
git clone https://github.com/peerbench/node-deploy.git
cd node-deploy
```

Then follow **[docs/deploy-gcp.md](docs/deploy-gcp.md)**.

## What's in here

- `docs/deploy-gcp.md` — step-by-step deployment guide for GCP. Can be
  followed manually or pasted into a coding agent (Claude Code, Codex, etc.)
  which will walk you through it interactively.
- `terraform/gcp/` — OpenTofu / Terraform scripts that create all the
  infrastructure (Cloud Run, Cloud SQL, Load Balancer, auto-update
  function, etc.) in a single `tofu apply`.

## Updates

Your node polls the official PeerBench container image on Docker Hub
every few minutes and auto-updates when a new version is published.
You never need to redeploy manually.

## For AI coding agents

Open `docs/deploy-gcp.md` in raw view. The top of the file contains a
system prompt that turns you into an interactive deployment CLI — follow
it.
