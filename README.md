# PeerBench Node Deploy

[![Docker Image](https://img.shields.io/docker/v/leipniz/pbfed-node?label=docker&logo=docker)](https://hub.docker.com/r/leipniz/pbfed-node)
[![Image Size](https://img.shields.io/docker/image-size/leipniz/pbfed-node/latest?logo=docker)](https://hub.docker.com/r/leipniz/pbfed-node)

Deployment scripts for running your own PeerBench federation node.

## Supported platforms

| Platform | Guide | Status |
|---|---|---|
| Google Cloud Platform | [docs/deploy-gcp.md](docs/deploy-gcp.md) | ✅ Available |
| AWS | — | 🛠️ Planned |
| Azure | — | 🛠️ Planned |
| Render | — | 🛠️ Planned |
| Self-hosted (Docker Compose) | — | 🛠️ Planned |

More platforms will be added. Each has its own guide under `docs/` and
scripts under `terraform/<platform>/` (or equivalent).

## Quick start

```bash
git clone https://github.com/peerbench/node-deploy.git
cd node-deploy
```

Then follow the guide for your chosen platform (see table above).

## Updates

Your node polls the official PeerBench container image on Docker Hub
every few minutes and auto-updates when a new version is published.
You never need to redeploy manually.

## For AI coding agents

Open the platform-specific guide (e.g. `docs/deploy-gcp.md`) in raw
view. The top of each guide contains a system prompt that turns you
into an interactive deployment CLI — follow it.
