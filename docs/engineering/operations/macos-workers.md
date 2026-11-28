# macOS workers

Start here for anything about native macOS compute workers: the Mac hosts
that run Xcode, SwiftPM, and iOS simulator work outside the Linux cluster.
This page holds only the shape and the rules. Every detail lives on exactly
one page linked below, so follow the link rather than relying on a summary.

## Topology

- Web, the single home worker, Linux compute, MySQL, object storage, ingress,
  and search volumes stay in Linux (k3s or managed services).
- Each Mac host runs two root-managed launchd services, `com.syrus.worker`
  (`bin/macos-worker` as `syrus-worker`) and `com.syrus.updater`
  (`/usr/local/libexec/syrus/syrus-macos-updater` as root).
- Macs are outbound-only clients of the database, storage, the Syrus host,
  GitHub, model providers, and registries. Nothing in the cluster connects to
  a Mac.
- Queues: `runs-macos-arm64`, `merges-macos-arm64`, and the host's own
  `resume-<worker-storage-key>`. The full layout is in
  [the queue topology table](multi-worker.md#native-macos-compute-workers).

## Invariants

- **Compute only.** `bin/macos-worker` forces `SYRUS_ROLE=worker`,
  `config/queue.compute.yml`, and `SOLID_QUEUE_SKIP_RECURRING=1`. A Mac never
  consumes chat, polling, indexing, cleanup, videos, or control-plane queues.
- **Macs never run migrations.** A deploy activates the Mac release only after
  production's migrations have run.
- **Every production deploy updates every Mac** (`Deploy::MacosWorkers`), and
  the release rolls out immediately. The drain flow is only for updating one
  host at a time by hand.
- **Version skew means no work.** A Mac on a revision other than the active
  release gets no new Runs (`RunQueueResolver`), and a Run it has already
  claimed is handed back (`RunJob`).
- **The release names its own revision.** The release's `GIT_SHA` file wins
  over any `GIT_SHA` in the env file.
- **Nothing comes from Homebrew or `/usr/local`.** Each release pins its
  toolchain, which is installed under `/opt/syrus`. launchd starts with
  `PATH=/usr/bin:/bin:/usr/sbin:/sbin`.
- **The worker cannot change its own code.** Releases are root-owned. The
  updater lives outside the release tree, verifies the signature and then the
  SHA-256, and runs no release code as root.
- **Connections are direct, not tunnelled.** The database is reached through
  an address-restricted LoadBalancer and storage through HTTPS. Never use
  `kubectl port-forward`.
- **Restarts are graceful.** On SIGTERM the worker drains for up to 3540s
  (`SOLID_QUEUE_SHUTDOWN_TIMEOUT`), inside launchd's `ExitTimeOut` of 3600s.
- **The admin worker restart is role-wide.** It restarts Mac workers too.
- **Hosts are provisioned by script only.** `bin/install-macos-worker` is
  idempotent, and `bin/uninstall-macos-worker` reverses it.

## When you need to… read…

| When you need to… | Read |
| --- | --- |
| Set up a new Mac host | [Host: install](macos-worker-host.md#install) |
| Know what goes in `/etc/syrus/worker.env` | [Host: env file contract](macos-worker-host.md#env-file-contract) |
| Find a path on the host | [Host: filesystem layout](macos-worker-host.md#filesystem-layout) |
| Bump Ruby, Node, mise, or the MySQL client | [Host: pinned toolchain](macos-worker-host.md#pinned-toolchain) |
| Open the network for a Mac | [Host: network requirements](macos-worker-host.md#network-requirements) |
| Rebuild a wiped host, or rehearse doing so | [Host: reinstall](macos-worker-host.md#reinstall-a-host) |
| Understand what a deploy does to the Macs | [Updates: every deploy](macos_worker_updates.md#every-deploy-updates-the-mac-workers) |
| Create the signing key or a worker token | [Updates: one-time setup](macos_worker_updates.md#one-time-setup) |
| Understand the updater | [Updates: how the updater works](macos_worker_updates.md#how-the-updater-works) |
| Update one host by hand, or clear a stuck drain | [Updates: drain-aware updates](macos_worker_updates.md#drain-aware-manual-updates) |
| Fix a Mac that is blocked, stale, or failing | [Troubleshooting](macos-worker-troubleshooting.md) |
| Change the Mac scripts safely | [Pitfalls: macOS hosts](../pitfalls/macos-hosts.md) |
| Find the code | [Map: macOS workers](../maps/macos-workers.md) |
| Run iOS Jobs on the pool | [iOS compute runbook](ios-compute.md) |

## Health check

```bash
sudo launchctl print system/com.syrus.worker | grep -E 'state|last exit'   # on the host
sudo -u syrus-worker /opt/syrus/current/bin/macos-worker --check --env-file /etc/syrus/worker.env
tail -n 50 /var/log/syrus/updater.log /var/log/syrus/worker.err.log
curl -fsS -H "Authorization: Bearer $SYRUS_API_TOKEN" "$SYRUS_URL/api/v1/admin/macos_worker_releases/status"
curl -fsS -H "Authorization: Bearer $SYRUS_API_TOKEN" "$SYRUS_URL/api/v1/admin/queue/workers"
```

Use `macos-worker --check`, not `macos-worker-check` directly. The wrapper
activates the pinned toolchain first; from a login shell the bare check
fails on the shell's Homebrew `PATH`.

Return to the [operations index](README.md).
