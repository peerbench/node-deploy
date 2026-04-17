# peerBench Node Deploy

[![Docker Image](https://img.shields.io/docker/v/leipniz/pbfed-node?label=docker&logo=docker)](https://hub.docker.com/r/leipniz/pbfed-node)
[![Image Size](https://img.shields.io/docker/image-size/leipniz/pbfed-node/latest?logo=docker)](https://hub.docker.com/r/leipniz/pbfed-node)

Deployment scripts for running your own peerBench federation node.

## For operators

Open the guide for your platform, copy it, paste into your AI coding agent (Claude Code, Codex, Cursor, etc.). The agent handles the rest.

## Supported platforms

| Platform | Guide | Local tools |
|---|---|---|
| Google Cloud Platform | [docs/deploy-gcp.md](docs/deploy-gcp.md) | `gcloud`, `tofu` (or `terraform` 1.5+), `git` |
| Render + Supabase (free tier, no custom domain) | [docs/deploy-render-supabase.md](docs/deploy-render-supabase.md) | `supabase`, `render`, `curl`, `git` |

The agent detects which local tools are missing and offers to install them — you don't have to pre-install anything.
