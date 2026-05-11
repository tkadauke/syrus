---
title: Kubernetes (k3s / k8s)
description: Production-grade Syrus deployment via Helm. The hard-mode path.
---

<!-- STUB. Implementation issue: bundled with the deployment docs
     issue. Depends on the Helm chart (#182) landing.

     Content brief:
     - Be honest: "this is hard mode; the maintainer spent days 2-5
       of the project just bootstrapping this. Few teams run k3s
       and most use cases are well-served by Docker Compose."
     - Once the Helm chart (#182) lands: `helm install syrus
       ./syrus` flow
     - Until then: link to the maintainer's k3s manifests as
       reference (with a "your mileage will vary" disclaimer)
     - Required prerequisites: ingress controller, persistent
       storage class, MySQL (in-cluster or external), secrets
       management
     - Per-user-credentials encryption setup
     - Ingress + TLS (cert-manager)
     - Backup story for `$SYRUS_DATA_ROOT` PVC + MySQL
     - Monitoring hooks (Prometheus once #197/#198 land)
-->

# Kubernetes deployment

The production path for teams running Syrus at scale.

> **Heads up.** This is the hard-mode path. The maintainer spent
> days 2–5 of the Syrus project just bootstrapping a real cluster
> deployment. Few teams run k3s, and most self-host use cases are
> better served by [Docker Compose](/docs/deployment/docker-compose).
> If you're sure you want Kubernetes, read on.

<!-- TODO: full content (depends on Helm chart #182) -->
