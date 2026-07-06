---
title: Deployment
description: Ways to run Syrus — pick the smallest path that gives you the full loop you need.
---

# Deployment

Syrus has one recommended local app path and a few more specialized
paths. Start with the prebuilt Docker Compose install; move down the
list only when you need source changes, custom packages, or cluster
operations.

| Path | Audience | Setup time | Use case |
| --- | --- | --- | --- |
| **1. Download the macOS app** | Mac users who want zero terminal | ~2min + image download | [Desktop app](/docs/desktop): DMG install, guided backend setup, web UI in a native window, menu-bar inbox, auto-updates. |
| **2. Run the app locally** | Developers / small teams | ~5min | `install.sh --docker` pulls the prebuilt Docker Compose image. Full web + worker + SQLite + GitHub PR loop. |
| **3. Build or customize the local image** | Operators changing Syrus or adding OS packages | 20-40min first build | `bin/compose-up` builds from the checkout and applies `EXTRA_APT_PACKAGES` / `Dockerfile.local`. |
| **4. Develop Syrus from source** | Syrus contributors | Toolchain-dependent | `install.sh --bare-metal`, `bin/setup`, and `bin/dev` for fast reloads. |
| **5. Deploy to a cluster** | Teams running real infra | Infrastructure-dependent | Kubernetes/k3s hard mode. The public Helm/chart path is still not a complete artifact. |

## Decision tree

- **On a Mac and want the easiest start?** [Download the desktop app](/docs/desktop).
- **Running Syrus for yourself or a small team?** Use [Docker Compose](/docs/deployment/docker-compose).
- **Need system packages or source changes in the image?** Use the source/custom build path in [Docker Compose](/docs/deployment/docker-compose#build-or-customize-the-image).
- **Working on Syrus itself?** Use the bare-metal source path in the project README.
- **Production at scale?** Read [Kubernetes](/docs/deployment/kubernetes), including the current packaging status.

## Run Locally

[Docker Compose](/docs/deployment/docker-compose) runs the real Syrus app
on one machine. The default command pulls the prebuilt
`ghcr.io/tkadauke/syrus-backend` image, generates local secrets, starts web
and worker containers, and stores the SQLite databases plus workflow
workspaces in one named Docker volume.

## Docker Compose

[Docker Compose](/docs/deployment/docker-compose) is the recommended
self-host path for developers and small teams. It runs the Rails web app,
the Solid Queue worker, and SQLite together, then lets you add a GitHub
repository, label an issue, and watch Syrus open a pull request.

If you are a Ruby developer with the toolchain already installed, you
can also run from source with `git clone`, `bundle install`, and
`bin/dev`. Docker Compose is still the recommended path for most users
because it owns the answers to "what else should I install?"

## Kubernetes

[Kubernetes](/docs/deployment/kubernetes) is for teams that already have
ingress, persistent storage, secrets management, backups, and operational
monitoring. It is the hard-mode path; use it when you need cluster-native
operations, not because it looks more official.
