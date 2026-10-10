---
title: Kubernetes (k3s / k8s)
description: Production-grade Syrus deployment status and requirements. The hard-mode path.
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
  `$SYRUS_DATA_ROOT` PVC and the dedicated `syrus-search` PVC.
- A MySQL strategy: managed MySQL, an operator-managed in-cluster MySQL,
  or a chart dependency with explicit backup/restore ownership.
- A secret management pattern for Rails secrets, database credentials,
  GitHub package access if needed, and any image-pull credentials.
- A rollout process that accounts for long-running agent jobs. Deploys
  can interrupt active worker pods; Syrus has stale-run cleanup, but the
  better operational answer is to schedule upgrades deliberately.

## Hybrid k3s plus native macOS workers

Native macOS is not a supported k3s node target for Syrus. You can run Linux
VMs on Mac hardware and join those VMs to k3s, but that does not provide native
Xcode, signing, or iOS simulator execution. The supported shape is a Linux k3s
cluster for web, home, and ordinary Linux compute, plus a pool of external Mac
hosts that run Syrus worker processes under launchd.

In that topology:

- k3s runs the web pods, the single home worker, Linux compute workers, MySQL,
  object storage if self-hosted, ingress, and the search/data volumes.
- Mac minis or other Apple hosts run `/opt/syrus/current/bin/macos-worker`
  outside Kubernetes and connect outbound to the same Syrus services.
- Mac workers consume only compute queues selected by their advertised
  capabilities, such as `runs-macos-arm64`, `merges-macos-arm64`, and their
  storage-affinity `resume-<worker-storage-key>` queues.
- Mac workers do not consume `chat`, `polling`, `indexing`, `cleanup`,
  `control_plane`, `videos`, or other home/control-plane queues.

Example topology:

| Tier | Runs where | Queues / responsibility |
| --- | --- | --- |
| Web | k3s Deployment | HTTPS app, API, admin UI, metrics |
| Home worker | one k3s pod | `chat`, `polling`, `indexing`, `cleanup`, `control_plane`, `videos` |
| Linux compute | k3s Deployment or DaemonSet | `runs`, `runs-linux-amd64`, `merges`, `merges-linux-amd64`, local resume queue |
| Mac mini pool | external launchd services | `runs-macos-arm64`, `merges-macos-arm64`, compatible resume queues |
| Data services | k3s or managed services | MySQL, object/artifact storage, search/data volumes |

## Values to configure

The chart should expose, at minimum, values for:

- Web image, worker image, tag, pull policy, and image pull secrets.
- Web replicas and worker replicas.
- MySQL host, database, username, and password secret references.
- `RAILS_MASTER_KEY`, `SECRET_KEY_BASE`, and Active Record Encryption
  secret references.
- Optional per-worker `SYRUS_WORKER_CAPABILITIES` values when some worker
  pools should advertise `os:macos` instead of the default Linux placement.
- `$SYRUS_DATA_ROOT` and `syrus-search` PVC size, storage class, access mode,
  and retention policy.
- Hostname, ingress class, TLS secret, and cert-manager issuer.
- Worker resource requests and limits. Agent runs can be memory- and
  network-heavy compared with ordinary Rails requests.

## External Mac worker network access

Mac workers are outbound clients. They do not need inbound SSH or Kubernetes
NodePort access from the cluster for normal operation. They do need outbound
network access to every service their Runs may touch:

- The primary MySQL or queue database used by the k3s deployment.
- Object or artifact storage, such as S3 or MinIO, when the installation uses
  it for attachments, artifacts, releases, or worker update archives.
- The Syrus web/API origin configured in `SYRUS_APP_HOST`, including the Mac
  worker update endpoints if pull-based updates are enabled.
- GitHub and any configured Git remotes or package registries.
- Model provider APIs used by the instance.
- Language/package registries needed by target repositories: for example npm,
  RubyGems, Go proxies, CocoaPods, Swift package mirrors, Maven, PyPI, or
  private registries.
- Internal services required by the repositories being built or tested, such
  as private artifact mirrors, signing services, staging APIs, or license
  servers.

Keep firewall rules one-way where possible: allow the Macs to dial the
cluster, storage, and internet dependencies; do not require the k3s control
plane to initiate sessions into the Mac pool.

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

External Mac workers need the same application identity as production worker
pods because they boot Rails, decrypt credentials, claim Solid Queue work, and
write Run state. The root-owned `/etc/syrus/worker.env` should include:

- `SECRET_KEY_BASE`.
- `RAILS_MASTER_KEY` or all three `ACTIVE_RECORD_ENCRYPTION_*` values.
- MySQL settings, including host, database, username, and password.
- Storage credentials and endpoint values when S3 or MinIO is enabled.
- GitHub and model credentials only when the deployment relies on process-level
  credentials rather than per-user encrypted credentials.
- `SYRUS_MACOS_WORKER_TOKEN` for updater status reports and desired-release
  polling.
- Artifact verification material, including the release checksum metadata and
  any trust anchors needed to fetch it from private storage.

Mac workers must not run database migrations. The cluster deploy should run
the new release's database migrations before any web or worker workload is
rolled to the new image, then the Mac pool can move to a schema-compatible
worker artifact.

That ordering is intentional: it avoids new worker code running against an old
schema, but it means old code may run briefly against the new schema while the
rollout is in progress. Write production migrations with that expand/contract
contract in mind: additive changes first, destructive changes only after the
old code has been removed from service.

Cluster worker entrypoints should also check for pending migrations before
starting queue consumers. A worker whose image expects migrations that have not
run yet should fail at startup instead of claiming work and surfacing the
problem later as an unrelated job failure.

## Ingress and TLS

Expose only the web service. Worker pods do not need inbound traffic.

With cert-manager, the usual shape is:

- Create or reuse a `ClusterIssuer` or namespace-scoped `Issuer`.
- Configure the chart ingress host for the Syrus hostname.
- Set the ingress TLS secret name.
- Add the cert-manager issuer annotation expected by your ingress stack.

Syrus uses browser sessions and live UI updates, so run it behind HTTPS
for any non-local installation.

## Terminal relay addressing

If you enable the labs terminal feature, each worker pod must advertise a relay
address that web pods can connect to directly. In k3s, set the worker
container's `MY_POD_IP` and `SYRUS_TERMINAL_HOST` from the pod IP with the
Downward API:

```yaml
env:
  - name: MY_POD_IP
    valueFrom:
      fieldRef:
        fieldPath: status.podIP
  - name: SYRUS_TERMINAL_HOST
    valueFrom:
      fieldRef:
        fieldPath: status.podIP
```

This is internal pod-to-pod traffic over the CNI network, such as Flannel in
k3s. Do not route terminal relay sockets through Traefik or public ingress.

## Data and backups

Back up three things:

- **MySQL**: the source of truth for users, encrypted credentials,
  repositories, Jobs, Workflows, Runs, logs, and artifacts.
- **`$SYRUS_DATA_ROOT` PVC**: bare clone cache, workflow workspaces, and
  files needed by active or recently completed Workflows.
- **`syrus-search` PVC**: the dedicated SQLite FTS5 chat search database.

For MySQL, use the backup mechanism that belongs to your MySQL strategy:
managed snapshots, operator backups, or scheduled `mysqldump`. For the
PVC, use your cluster storage snapshot mechanism or a volume backup tool
such as Velero with CSI snapshots.

The data-root and search PVC mounts must be writable by the container's
`rails` user (`1000:1000`) where writes happen. Both web and worker pods mount
`syrus-search` read-write at `/home/rails/.syrus-search` because Rails touches
the search SQLite database during boot and migration preparation, not only from
background indexing work. Set
`SEARCH_DATABASE_PATH=/home/rails/.syrus-search/search.sqlite3`. The published
images create `/home/rails/.syrus` and `/home/rails/.syrus-search` with that
ownership for first-mount volume initialization; custom mount paths or
pre-provisioned volumes should set matching ownership before pods start.

The database matters most for long-term recovery. The data-root PVC
matters most for active runs and operational smoothness. Restoring the
database without the PVC should still leave historical Jobs visible, but
running Workflows and cached clone state may need cleanup or retry.

## Monitoring

The immediate operational signals are Rails logs, worker logs, queue
depth, failed Runs, stale running Runs, GitHub rate-limit errors, and
agent invocation failures. Admin users also see a banner when the worker
data-root filesystem approaches full: warning at 85% used, critical at
95% used or less than 5GB free. The banner reports the used percentage,
available space, and `$SYRUS_DATA_ROOT` path so operators can clean old
workflow workspaces or resize the PVC before clone and prepare steps
start failing. Syrus also exposes an authenticated `GET /metrics` endpoint in
the Prometheus text exposition format -- queue health, product usage, landing
queue/run throughput, worker CPU/memory/disk and admission decisions, and fleet
(pod version, spawned process) gauges and counters. Route container logs to
your cluster logging stack, scrape `/metrics` from a Prometheus instance, and
alert on repeated worker failures or growing queue depth.

For split k3s worker pools, set `SYRUS_WORKER_CAPABILITIES` on each worker
Deployment or DaemonSet to match the worker OS. Linux compute workers can
usually rely on detected `os:linux`, while a native macOS worker pool should
advertise `os:macos`. The normalized capability map appears in Admin Workers,
worker health, and queue diagnostics.
When no live worker matches a planned workflow phase, Syrus pauses that
workflow with queue-capability details and retries admission; enqueue-time
checks remain as a backstop if capacity changes after admission.

Native macOS workers run outside Kubernetes under launchd. They should use
`bin/macos-worker --env-file /etc/syrus/worker.env`, which forces
`SYRUS_ROLE=worker`, `SOLID_QUEUE_CONFIG=config/queue.compute.yml`, and
`SOLID_QUEUE_SKIP_RECURRING=1` so the host consumes only compute/capability
queues. Use `bin/macos-worker-check --env-file /etc/syrus/worker.env` before
loading the LaunchDaemon to validate Ruby/Bundler, Node/npm, Git, Xcode Command
Line Tools, full Xcode, simulator runtimes, and required production
credentials. The launchd template is checked in at
`config/launchd/com.syrus.worker.plist`; install it for a dedicated
`syrus-worker` user with a persistent `/var/lib/syrus` data root, release
symlink `/opt/syrus/current`, logs under `/var/log/syrus`, and a root-owned env
file under `/etc/syrus`. That env file must include the normal production app
identity and secrets, including `SYRUS_APP_HOST`, `SECRET_KEY_BASE`, Active
Record encryption keys or `RAILS_MASTER_KEY`, DB credentials, storage
credentials, `SYRUS_WORKER_POOL_NAME`, and `SYRUS_WORKER_CAPABILITIES`.
Release builds publish a source artifact named
`syrus-worker-macos-arm64-<git_sha>.tar.gz` with checksums. It carries the
tracked app source, binstubs, lockfiles, package manifests, launchd template,
`GIT_SHA`, `SYRUS_VERSION`, and worker release metadata; native gems and other
host-specific dependencies are installed on each Mac during activation. Mac
workers should update only after the k3s cluster has deployed schema-compatible
code and run migrations; the Mac workers themselves should not run migrations.

The Mac pool lifecycle is launchd-based:

- `com.syrus.worker` keeps the compute worker process running.
- `com.syrus.updater` polls Syrus or `SYRUS_UPDATE_METADATA_URL` for desired
  release metadata.
- The updater downloads the source artifact, verifies its SHA-256, installs
  host-local dependencies, flips `/opt/syrus/current`, and restarts the worker.
- Rolling updates drain one Mac at a time. Drained hosts finish active Runs,
  stop accepting new compatible work, activate the desired release, heartbeat
  at the new `git_sha`, and then rejoin the pool.

Admin queue and worker-health surfaces show worker capabilities, drain/update
state, stale versions, failed update reports, selected queues, and
`no_capable_worker` admission details. Those surfaces are the first place to
check when a Mac-capability Workflow is waiting.

## Hybrid troubleshooting

- **No capable worker online**: verify a fresh Mac worker heartbeat, the
  advertised capability (`os:macos`), and that the process consumes
  `runs-macos-arm64` or the expected resume queue. Check whether every Mac is
  draining or updating.
- **Stale Mac worker version**: check updater status in worker health, confirm
  `SYRUS_MACOS_WORKER_TOKEN` can read the desired release, verify artifact URL
  access, and compare the worker's reported `git_sha` with the desired release.
- **Xcode not installed or not licensed**: run `bin/macos-worker-check
  --env-file /etc/syrus/worker.env` on the host, then fix `xcode-select`,
  accept the Xcode license, and install required Command Line Tools.
- **Missing simulators**: install the required iOS runtime in Xcode, then rerun
  the worker check. Simulator availability is reported in diagnostics rather
  than as an execution capability.
- **Keychain or signing failures**: confirm the launchd user owns or can unlock
  the signing keychain, has the required certificates and provisioning
  profiles, and can reach any internal signing or notarization services needed
  by the target repo.
