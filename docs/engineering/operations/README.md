# Operations

- [Plugin registry](plugin-registry.md) — index layout, serving, trust, and revocation.

These are maintainer procedures for deploying, observing, diagnosing, and
recovering Syrus itself. Operator feature instructions remain in
`config/syrus_docs/`; public installation guidance remains in `website/`.

- [Deployment](deployment.md) — build, migrate, roll out, and verify.
- [Deploying Syrus](deploying-syrus.md) — two-version rollouts, PWA behavior,
  Kubernetes ordering, and migration-job budgets.
- [Data retention](data-retention.md) — retention registry, sweeping,
  archiving, pruning, size estimation, and extension points.
- [Per-spawn resource limits](resource-limits.md) — operational rollout note
  for execution confinement.
- [Runtime image registry](runtime-image-registry.md) — OCI provider configuration, credential roles, diagnostics
- [Standard coworker base image](coworker-base-image.md) — all-provider base build definition, identity, publishing, updates
- [Production debugging](production-debugging.md) — inspect Kubernetes,
  processes, logs, queues, workers, and data safely.
- [Workflow recovery](workflow-recovery.md) — diagnose and repair stuck or
  failed Jobs, WorkUnits, Workflows, Runs, and workspaces.
- [Detailed deployed-operations reference](deployed-reference.md) — deployed
  testing, cluster-debugging, workflow, and deploy-target procedures.
- [Release troubleshooting](../../release-troubleshooting.md)
- [Releasing](../../releasing.md)
- [macOS worker updates](macos_worker_updates.md)
- [Docker Compose](docker_compose.md)
- [Multi-worker operations](multi-worker.md) — queue partitioning, native
  macOS workers, storage remediation, and capacity sizing.
- [External plugin operations](external-plugins.md) — install, replace,
  diagnose, and remove a dropped-in plugin directory.
- [Metrics operations](metrics.md) — scrape authentication, readiness, alert
  rules, and the operator metric catalog.
- [Observability operations](observability.md) — on-demand process diagnostics
  with SIGUSR2 and Kubernetes.
- [Preview environments](preview-environments.md) — deployment variables,
  wildcard routing, preview processes, and production setup.
- [Admin recovery](admin-recovery.md) — deployed web and worker restart
  procedures and checks.
- [iOS and macOS compute](ios-compute.md) — native worker installation,
  launchd, environment, updates, and pool topology.
- [Speech-to-text](chat-speech-to-text.md) — transcription daemon deployment,
  configuration, logs, and diagnosis.
- [External PR ingestion](external-pr-ingestion.md) — recover older preempted
  issue Jobs that still have open external pull requests.

Return to the [engineering documentation index](../README.md).
