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
- [Runtime image registry](runtime-image-registry.md) — OCI provider configuration, credential roles, diagnostics
  for execution confinement.
- [Standard coworker base image](coworker-base-image.md) — all-provider base build definition, identity, publishing, updates
- [Production debugging](production-debugging.md) — inspect Kubernetes,
  processes, logs, queues, workers, and data safely.
- [Workflow recovery](workflow-recovery.md) — diagnose and repair stuck or
  failed Jobs, WorkUnits, Workflows, Runs, and workspaces.
- [Detailed deployed-operations reference](deployed-reference.md) — deployed
  testing, cluster-debugging, workflow, and deploy-target procedures.
- [Release troubleshooting](../../release-troubleshooting.md)
- [Releasing](../../releasing.md)
- [Docker Compose](docker_compose.md)
- [macOS workers](macos-workers.md) — start here for native Mac compute
  hosts: topology, invariants, routing, and the health check.
  - [Host](macos-worker-host.md) — prerequisites, env file, install,
    filesystem, pinned toolchain, network, and reinstall.
  - [Updates](macos_worker_updates.md) — the deploy phase, signing key and
    token, the updater, the release artifact, and manual drains.
  - [Troubleshooting](macos-worker-troubleshooting.md) — symptom, confirm,
    cause, fix.
- [Multi-worker operations](multi-worker.md) — queue partitioning, the
  hybrid queue topology, storage remediation, and capacity sizing.
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
- [iOS compute](ios-compute.md) — iOS repository configuration, Jobs,
  placement, and missing-capability blockers (Mac hosts: see macOS workers).
- [Speech-to-text](chat-speech-to-text.md) — transcription daemon deployment,
  configuration, logs, and diagnosis.
- [External PR ingestion](external-pr-ingestion.md) — recover older preempted
  issue Jobs that still have open external pull requests.

Return to the [engineering documentation index](../README.md).
