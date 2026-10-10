---
title: macOS Workers
description: Run native Mac compute workers for Xcode and iOS simulator workloads.
---

# macOS Workers

Native macOS workers run outside Kubernetes and consume only capability-matched
compute queues. They are for Xcode and iOS simulator work; they are not chat,
search, or control-plane workers.

For the end-to-end operator workflow of planning iOS Jobs, selecting primary
execution capabilities, routing target graders, and diagnosing missing-capacity
blockers, see the [iOS Compute Runbook](/docs/ios-compute-runbook).

## Supported Deployment Shape

Use Mac workers as an external compute pool next to a Linux Syrus deployment.
In k3s, keep web, home worker, Linux compute, MySQL, object storage, ingress,
and search/data volumes in the cluster. Run each Mac host as a native launchd
worker that connects outbound to those services.

Do not join native macOS directly to k3s as the Syrus worker target. Running a
Linux VM on Mac hardware can add Linux capacity to the cluster, but it does not
make Xcode, signing identities, or iOS simulators available to Syrus Runs.

The expected Mac worker entrypoint is:

```bash
/opt/syrus/current/bin/macos-worker --env-file /etc/syrus/worker.env
```

The wrapper forces the host into compute-worker mode with
`SYRUS_ROLE=worker`, `SOLID_QUEUE_CONFIG=config/queue.compute.yml`, and
`SOLID_QUEUE_SKIP_RECURRING=1`. A typical env file includes:

```dotenv
RAILS_ENV=production
SYRUS_APP_HOST=https://syrus.example.internal
SYRUS_DATA_ROOT=/var/lib/syrus
SYRUS_WORKER_POOL_NAME=macos-xcode
SYRUS_WORKER_CAPABILITIES=os:macos,arch:arm64,toolchain:xcode,runtime:ios_simulator
GIT_SHA=<release sha>
```

Mac workers with those capabilities consume the macOS compute lanes such as
`runs-macos-arm64` and `merges-macos-arm64`, plus their own
`resume-<worker-storage-key>` queue for storage-affinity retries. They should
not consume broad Linux work or home queues.

## Network Requirements

Mac workers are outbound clients. Allow them to reach:

- The MySQL or queue database used by the Syrus deployment.
- S3, MinIO, or other object/artifact storage used by the instance.
- The Syrus web/API origin in `SYRUS_APP_HOST`.
- GitHub, configured Git remotes, model provider APIs, and package registries.
- Private services target repos need during tests, builds, signing, or deploys.
- The release artifact location used by the updater, if it differs from Syrus.

Inbound SSH from the k3s control plane is not part of the normal lifecycle.
Operators can still use their own host-management tooling, but Syrus updates
Mac workers through a pull updater.

## Secrets

The root-owned `/etc/syrus/worker.env` must carry the same production Rails
identity a worker pod needs:

- `SECRET_KEY_BASE`.
- `RAILS_MASTER_KEY` or all three `ACTIVE_RECORD_ENCRYPTION_*` keys.
- Database host/name/user/password values.
- Storage credentials and endpoints when object storage is enabled.
- `SYRUS_MACOS_WORKER_TOKEN` for update polling and status reports. Generate it
  with `bin/rails syrus:macos_worker_token`.
- GitHub/model credentials only if your deployment uses process-level
  credentials instead of per-user encrypted credentials.
- Any artifact verification trust needed to fetch private release archives.

Keep signing certificates, provisioning profiles, and Keychain passwords in the
host-specific secret system you already use for Apple builds. The launchd user
must be able to unlock or access those identities without an interactive login
session.

Mac workers should not run database migrations. Deploy the k3s/web release with
its pre-rollout migration step first, then roll the Mac pool to a
schema-compatible worker artifact. Migrations in that cluster release must stay
backward compatible with the old worker code until the old workers are gone.

## Launchd Lifecycle

Each host uses a dedicated unprivileged user, persistent `SYRUS_DATA_ROOT` such
as `/var/lib/syrus`, release checkouts under `/opt/syrus/releases/<sha>`, an
`/opt/syrus/current` symlink, and logs under `/var/log/syrus`. The launchd
template lives at `config/launchd/com.syrus.worker.plist`.

Before loading or reloading the worker, run:

```bash
/opt/syrus/current/bin/macos-worker-check --env-file /etc/syrus/worker.env
```

The check validates Ruby/Bundler, Node/npm, Git, Xcode Command Line Tools, full
Xcode selection, iOS simulator runtimes, required env, and production
credentials without starting Solid Queue. The continuous worker readiness
probes use the same read-only posture: Syrus records version and listing facts
from `sw_vers`, `xcode-select`, `xcodebuild -version`, `xcrun --find
xcodebuild`, and `xcrun simctl list`, but does not mutate keychains, signing
state, simulator contents, or selected devices.

## Pull-Based Updates

Mac hosts run two launchd services:

- `com.syrus.worker` starts `/opt/syrus/current/bin/macos-worker`.
- `com.syrus.updater` starts `/opt/syrus/current/bin/syrus-macos-updater`.

The updater polls Syrus or `SYRUS_UPDATE_METADATA_URL` for desired release
metadata, downloads the `syrus-worker-macos-*.tar.gz` artifact, verifies its
SHA-256, installs it into `/opt/syrus/releases/<sha>`, runs host-local
dependency setup, flips `/opt/syrus/current`, and restarts the worker service.

The worker env file keeps host-local state outside release directories:
`SYRUS_DATA_ROOT`, storage identity, credentials, logs, and shared dependency
caches remain in stable paths across releases. Old release directories are
kept only inside a bounded retention window for rollback.

Syrus records updater state in worker health. Admin views can distinguish
current, updating, failed, and stale Mac workers from the status each host
reports after polling or activation attempts.

## Rolling Updates

Mac worker updates are drain-aware and roll one host at a time. Syrus marks a
specific storage identity or hostname as draining, stops routing new compatible
Runs to that worker, waits for active Runs and spawned processes to finish,
then asks the host updater to activate the desired release.

The updater identifies itself when it polls Syrus for release metadata. Syrus
keeps desired release details visible to every Mac worker, but only returns
`enabled: true` to the selected worker once that worker is ready to update or
has been explicitly forced.

After the worker heartbeats at the desired `git_sha`, Syrus verifies that the
host still advertises `os:macos` and reports healthy Xcode diagnostics before
clearing the drain and moving to the next Mac. Admin worker health and queue
views show drain/update state, failed updates, stale versions, and force-restart
requests. If all Mac workers are draining or updating, Syrus does not advertise
Mac capacity for new macOS Runs.

Drain-aware updates are the normal pool-update path. The role-wide admin
restart mechanism can restart worker-role processes, but it is too broad for a
Mac mini pool with expensive iOS Runs in progress.

## Admin Observability

Admin worker health and queue views show the details you need to operate the
pool:

- Hostname, worker role, reported `git_sha`, and updater status.
- Normalized capabilities and capability probe diagnostics, including macOS
  version, architecture, selected developer directory, Xcode version/build,
  command-line-tool usability, available iOS simulator runtimes, and a bounded
  sample of available simulator devices.
- Consumed queues, including `runs-macos-arm64` and resume queues.
- Drain/update state and desired release metadata.
- `no_capable_worker` admission details when a Workflow cannot start, including
  the live worker queue/capability snapshots used to diagnose an iOS capacity
  shortage.

Mac host CPU/memory pressure charts may be sparse because some low-level health
metrics are Linux-specific. Capability, version, disk, queue, heartbeat, and
drain/update state still report normally.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| No capable worker online | Confirm a fresh heartbeat, `SYRUS_WORKER_CAPABILITIES`, `runs-macos-arm64` queue consumption, and whether all Macs are draining/updating. |
| Stale Mac worker version | Check updater status, `SYRUS_MACOS_WORKER_TOKEN`, desired release metadata, artifact URL access, and checksum verification failures. |
| Xcode not installed or licensed | Run `bin/macos-worker-check`, fix `xcode-select`, install Command Line Tools/full Xcode, and accept the Xcode license as needed. |
| Missing simulators | Install the required iOS runtime in Xcode and run `bin/macos-worker-check`; simulator availability is reported in diagnostics and advertised as `runtime:ios_simulator` when available. |
| Keychain or signing failures | Verify the launchd user can access the signing keychain, certificates, provisioning profiles, and any private signing/notarization services. |
| Package installs fail only on Macs | Check outbound registry access, host-local dependency caches, Xcode/SDK compatibility, and target-repo private registry credentials. |

## Why Pull Instead Of SSH

In k3s deployments, the Linux control plane should not need inbound SSH access
to every Mac mini. A pull updater works through the same outbound network path
the worker already needs for Syrus, keeps host-specific Xcode setup local to
the Mac, and lets each host activate a verified release atomically.
