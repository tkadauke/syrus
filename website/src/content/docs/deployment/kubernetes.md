---
title: Kubernetes (k3s / k8s)
description: Production-grade Syrus deployment via Helm. The hard-mode path.
---

# Kubernetes deployment

The production path for teams running Syrus at scale.

> **Heads up.** This is the hard-mode path. The maintainer spent
> days 2-5 of the Syrus project just bootstrapping a real cluster
> deployment. Few teams run k3s, and most self-host use cases are
> better served by [Docker Compose](/docs/deployment/docker-compose).
> If you're sure you want Kubernetes, read on.

## Status

The Helm chart is tracked by
[#182](https://github.com/tkadauke/syrus/issues/182). Once it lands, the
intended installation shape is:

```bash
helm repo add syrus https://tkadauke.github.io/syrus
helm repo update
helm install syrus syrus/syrus \
  --namespace syrus \
  --create-namespace \
  --values values.yaml
```

Until the chart is published, do not treat this page as a complete
manifest set. The maintainer's k3s manifests are not present in this
checkout as a publishable reference; when they are published, they should
be used as examples to adapt, not as a universal production baseline.

## Prerequisites

Before deploying Syrus to Kubernetes, have these pieces already working:

- An ingress controller such as Traefik, nginx ingress, or another
  controller standard for your cluster.
- A default persistent storage class that supports the worker's
  `$SYRUS_DATA_ROOT` PVC.
- A MySQL strategy: managed MySQL, an operator-managed in-cluster MySQL,
  or a chart dependency with explicit backup/restore ownership.
- A secret management pattern for Rails secrets, database credentials,
  GitHub package access if needed, and any image-pull credentials.
- A rollout process that accounts for long-running agent jobs. Deploys
  can interrupt active worker pods; Syrus has stale-run cleanup, but the
  better operational answer is to schedule upgrades deliberately.

## Values to configure

The chart should expose, at minimum, values for:

- Web image, worker image, tag, pull policy, and image pull secrets.
- Web replicas and worker replicas.
- MySQL host, database, username, and password secret references.
- `RAILS_MASTER_KEY`, `SECRET_KEY_BASE`, and Active Record Encryption
  secret references.
- `$SYRUS_DATA_ROOT` PVC size, storage class, and retention policy.
- Hostname, ingress class, TLS secret, and cert-manager issuer.
- Worker resource requests and limits. Agent runs can be memory- and
  network-heavy compared with ordinary Rails requests.

## Encrypted credentials

Syrus stores each user's GitHub token and agent credentials with Active
Record Encryption. In Kubernetes, set these secrets on every web and
worker pod:

```dotenv
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=...
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=...
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=...
```

Generate each value once with `openssl rand -hex 32`, back them up with
your cluster secrets, and reuse them for every pod in the installation.
If these variables are absent, Rails falls back to `RAILS_MASTER_KEY` and
encrypted Rails credentials.

If you rotate the Active Record Encryption keys, or rotate
`RAILS_MASTER_KEY` for an installation that relies on Rails credentials
for those keys, existing encrypted credentials become unreadable. The
symptom will look like users whose GitHub or agent credentials suddenly
disappeared or cannot be decrypted.

## Ingress and TLS

Expose only the web service. Worker pods do not need inbound traffic.

With cert-manager, the usual shape is:

- Create or reuse a `ClusterIssuer` or namespace-scoped `Issuer`.
- Configure the chart ingress host for the Syrus hostname.
- Set the ingress TLS secret name.
- Add the cert-manager issuer annotation expected by your ingress stack.

Syrus uses browser sessions and live UI updates, so run it behind HTTPS
for any non-local installation.

## Data and backups

Back up two things:

- **MySQL**: the source of truth for users, encrypted credentials,
  repositories, Jobs, Workflows, Runs, logs, and artifacts.
- **`$SYRUS_DATA_ROOT` PVC**: bare clone cache, workflow workspaces, and
  files needed by active or recently completed Workflows.

For MySQL, use the backup mechanism that belongs to your MySQL strategy:
managed snapshots, operator backups, or scheduled `mysqldump`. For the
PVC, use your cluster storage snapshot mechanism or a volume backup tool
such as Velero with CSI snapshots.

The data-root PVC mount must be writable by the container's `rails` user
(`1000:1000`). The published images create `/home/rails/.syrus` with that
ownership for first-mount volume initialization; custom mount paths or
pre-provisioned volumes should set matching ownership before worker pods
start.

The database matters most for long-term recovery. The data-root PVC
matters most for active runs and operational smoothness. Restoring the
database without the PVC should still leave historical Jobs visible, but
running Workflows and cached clone state may need cleanup or retry.

## Monitoring

The immediate operational signals are Rails logs, worker logs, queue
depth, failed Runs, stale running Runs, GitHub rate-limit errors, and
agent invocation failures. Prometheus integration is planned in
[#197](https://github.com/tkadauke/syrus/issues/197) and
[#198](https://github.com/tkadauke/syrus/issues/198); until then, route
container logs to your cluster logging stack and alert on repeated worker
failures or growing queue depth.
