# Operations

These are maintainer procedures for deploying, observing, diagnosing, and
recovering Syrus itself. Operator feature instructions remain in
`config/syrus_docs/`; public installation guidance remains in `website/`.

- [Deployment](deployment.md) — build, migrate, roll out, and verify.
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
- [Metrics operations](metrics.md) — scrape authentication, readiness, alert
  rules, and the operator metric catalog.
- [Observability operations](observability.md) — on-demand process diagnostics
  with SIGUSR2 and Kubernetes.

Return to the [engineering documentation index](../README.md).
