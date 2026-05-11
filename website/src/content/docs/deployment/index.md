---
title: Deployment
description: Three ways to run Syrus — pick the one that fits your situation.
---

# Deployment

Syrus has three deployment paths. Start with the smallest one that
answers your question; you can move up when you need real GitHub polling,
shared users, durable data, or cluster operations.

| Path | Audience | Setup time | Use case |
| --- | --- | --- | --- |
| **1. Try it locally** | Anyone curious | ~60s | Single Docker container running `bin/syrus dev` against your local repo. Pre-onboarding evaluation. |
| **2. Run it locally for real** | Developers / small teams | ~5min | Docker Compose with web + worker + MySQL. Full polling + PR flow against real GitHub repos. |
| **3. Deploy to a cluster** | Teams running real infra | ~30min | Helm chart for k3s/k8s. Production-grade, once the chart lands. |

## Decision tree

- **Just curious?** Use [Try it locally](/docs/deployment/try-it-locally).
- **Running Syrus for a team?** Use [Docker Compose](/docs/deployment/docker-compose).
- **Production at scale?** Use [Kubernetes](/docs/deployment/kubernetes).

## Try it locally

[Try it locally](/docs/deployment/try-it-locally) runs Syrus in a single
container against a repo already on your machine. It uses the same
agent-facing implementation step as the full app, but stops at a local
diff printed to stdout. This is the right path when you want to know
whether Syrus can make a useful change before you give it GitHub access.

## Docker Compose

[Docker Compose](/docs/deployment/docker-compose) is the recommended
self-host path for developers and small teams. It runs the Rails web app,
the Solid Queue worker, and MySQL together, then lets you add a GitHub
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
