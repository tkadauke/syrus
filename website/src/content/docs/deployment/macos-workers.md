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

After installing full Xcode and at least one iOS simulator runtime, use the
worker artifact's installer to establish the rest of the host contract:

```bash
sudo /path/to/unpacked-worker/bin/install-macos-worker \
  --env-file /etc/syrus/worker.env
```

The installer is idempotent, and `bin/uninstall-macos-worker` reverses it.
The installer does the following:

- creates the unprivileged `syrus-worker` service account and the persistent
  directories;
- installs the toolchain the release pins (Ruby, Node, `mise`, and the MySQL
  client library) under `/opt/syrus`, along with the pinned Claude Code and
  Codex CLIs;
- turns off interactive Git credential helpers for the service account;
- prepares and validates the release;
- loads the worker and updater LaunchDaemons.

Nothing the worker runs comes from Homebrew or `/usr/local`. Both are shared
with every other account on the host, so the worker ignores them even when
they are present.

You manage these prerequisites yourself: Xcode, simulator runtimes, the env
file, Apple signing identities, and the release-signing public key.

The installer refuses to run until the release-signing public key is
installed, root-owned, at `/etc/syrus/macos-worker-update-public.pem`. Keep
the matching private key on the machine you deploy or release from, and pass
its path as `SYRUS_MACOS_UPDATE_SIGNING_KEY_FILE` when building worker
releases.

The wrapper forces the host into compute-worker mode with
`SYRUS_ROLE=worker`, `SOLID_QUEUE_CONFIG=config/queue.compute.yml`, and
`SOLID_QUEUE_SKIP_RECURRING=1`. The release reports its own revision, so do
not set `GIT_SHA`. A typical env file includes:

```dotenv
RAILS_ENV=production
SYRUS_APP_HOST=https://syrus.example.internal
SYRUS_DATA_ROOT=/var/lib/syrus
SYRUS_WORKER_POOL_NAME=macos-xcode
SYRUS_WORKER_CAPABILITIES=os:macos,arch:arm64,toolchain:xcode,runtime:ios_simulator
```

Mac workers with those capabilities consume the macOS compute lanes such as
`runs-macos-arm64` and `merges-macos-arm64`, plus their own
`resume-<worker-storage-key>` queue for storage-affinity retries. They should
not consume broad Linux work or home queues.

## Network Requirements

Mac workers are outbound clients. Allow them to reach:

- The MySQL or queue database used by the Syrus deployment. Connect
  directly, for example through a LoadBalancer restricted to the Mac's
  address. Do not use a `kubectl port-forward` tunnel: it stalls under load
  and drops connections, and Syrus then treats the worker as dead.
- S3, MinIO, or other object/artifact storage, through its HTTPS endpoint.
- The Syrus web/API origin in `SYRUS_APP_HOST`, over HTTPS. Syrus serves the
  worker release itself.
- GitHub, configured Git remotes, model provider APIs, and package registries.
- Private services target repos need during tests, builds, signing, or deploys.

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
  with `bin/rails syrus:macos_worker_token`. It lasts 30 days unless you set
  `DAYS`, and a host stops updating once its token has expired.
- GitHub/model credentials only if your deployment uses process-level
  credentials instead of per-user encrypted credentials.

Keep signing certificates, provisioning profiles, and Keychain passwords in the
host-specific secret system you already use for Apple builds. The launchd user
must be able to unlock or access those identities without an interactive login
session.

Mac workers never run database migrations. The deploy activates the new Mac
release only after the cluster's migrations have run (see
[Pull-Based Updates](#pull-based-updates)). Migrations must still stay
backward compatible with the old worker code, because old workers finish
their in-flight Runs on it.

## Launchd Lifecycle

Each host uses a dedicated unprivileged user, persistent `SYRUS_DATA_ROOT` such
as `/var/lib/syrus`, release checkouts under `/opt/syrus/releases/<sha>`, an
`/opt/syrus/current` symlink, and logs under `/var/log/syrus`. The launchd
template lives at `config/launchd/com.syrus.worker.plist`.

To check a host, run the check through the wrapper. The wrapper puts the
pinned toolchain on `PATH` first:

```bash
sudo -u syrus-worker /opt/syrus/current/bin/macos-worker --check --env-file /etc/syrus/worker.env
```

Running `bin/macos-worker-check` directly from a login shell can fail on that
shell's Homebrew `PATH`. The check validates that Ruby and Node match the
release's pins and that `PATH` contains no Homebrew or `/usr/local` entries.
It also checks Bundler, npm, Git, `mise`, the Claude and Codex CLIs, Xcode Command Line Tools, full Xcode selection, iOS simulator runtimes,
required env, and production credentials without starting Solid Queue. The
continuous worker readiness probes use the same read-only posture: Syrus
records version and listing facts from `sw_vers`, `xcode-select`, `xcodebuild
-version`, `xcrun --find xcodebuild`, and `xcrun simctl list`, but does not
mutate keychains, signing state, simulator contents, or selected devices.

## Pull-Based Updates

Every production deploy updates the Mac workers, in three steps:

1. Before it touches the cluster, the deploy builds, signs, and uploads the
   worker release for the commit it is deploying.
2. Right after the cluster's migrations, it activates that release.
3. When the cluster rollout is done, it waits (15 minutes by default) until
   every live Mac reports the new revision.

From activation on, a Mac still running another revision takes no new work.
If a Mac fails to update, the deploy fails, but the cluster rollout is not
rolled back. Offline Macs are listed and update the next time they poll.

An activated release rolls out at once: no drain is needed. Each updater
installs the release and restarts its worker. On shutdown, the worker lets
in-flight Runs finish for up to an hour, the same budget compute pods get.

Mac hosts run two launchd services:

- `com.syrus.worker` starts `/opt/syrus/current/bin/macos-worker`.
- `com.syrus.updater` starts the root-owned
  `/usr/local/libexec/syrus/syrus-macos-updater`, outside the worker-writable
  runtime paths.

The updater polls Syrus or `SYRUS_UPDATE_METADATA_URL` for desired release
metadata over HTTPS, downloads the `syrus-worker-macos-*.tar.gz` artifact over
HTTPS, verifies its detached RSA/SHA-256 signature using the public key pinned
at `/etc/syrus/macos-worker-update-public.pem`, checks its SHA-256, installs it
root-owned into `/opt/syrus/releases/<sha>`, runs host-local dependency setup as
`syrus-worker`, flips `/opt/syrus/current`, and restarts the worker service.
Local `file://` update sources are rejected outside explicit test setups.

The worker env file keeps host-local state outside release directories:
`SYRUS_DATA_ROOT`, storage identity, credentials, logs, and shared dependency
caches remain in stable paths across releases. Old release directories are
kept only inside a bounded retention window for rollback.

Syrus records updater state in worker health. Admin views can distinguish
current, updating, failed, and stale Mac workers from the status each host
reports after polling or activation attempts.

## Manual One-Host Updates

Deploys do not use drains. To update one Mac at a time by hand instead,
use the drain-aware flow. Syrus marks a
specific storage identity or hostname as draining, stops routing new compatible
Runs to that worker, waits for active Runs and spawned processes to finish,
then asks the host updater to activate the desired release.

The updater identifies itself when it polls Syrus for release metadata. A
release that a deploy activated is enabled for every Mac immediately. For
any other release, Syrus returns `enabled: true` only to the selected worker,
once that worker is ready to update or has been explicitly forced.

After the worker heartbeats at the desired `git_sha`, Syrus verifies that the
host still advertises `os:macos` and reports healthy Xcode diagnostics before
clearing the drain and moving to the next Mac. Admin worker health and queue
views show drain/update state, failed updates, stale versions, and force-restart
requests. If all Mac workers are draining or updating, Syrus does not advertise
Mac capacity for new macOS Runs.

The role-wide admin restart mechanism restarts every worker-role process,
Mac workers included.

## Admin Observability

Admin worker health and queue views show the details you need to operate the
pool:

- Hostname, worker role, reported `git_sha`, and updater status.
- Normalized capabilities and capability probe diagnostics, including macOS
  version, architecture, selected developer directory, Xcode version/build,
  command-line-tool usability, available iOS simulator runtimes, and a bounded
  sample of available simulator devices. Tool probe statuses distinguish a
  missing or non-executable command from a command that ran and failed; probes
  use the worker's `PATH` while keeping the rest of the environment scrubbed.
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
| Stale Mac worker version | Check updater status and `/var/log/syrus/updater.log`, whether `SYRUS_MACOS_WORKER_TOKEN` has expired, the installed public key (signature failures), and HTTPS access to `SYRUS_APP_HOST`. |
| Mac takes no work after a deploy | Expected until it runs the active release; check its updater status. |
| Xcode not installed or licensed | Run the wrapped check, fix `xcode-select`, install Command Line Tools/full Xcode, and accept the Xcode license as needed. |
| Missing simulators | Install the required iOS runtime in Xcode and rerun the check; simulator availability is reported in diagnostics and advertised as `runtime:ios_simulator` when available. |
| Keychain or signing failures | Verify the launchd user can access the signing keychain, certificates, provisioning profiles, and any private signing/notarization services. |
| Package installs fail only on Macs | Check outbound registry access, host-local dependency caches, Xcode/SDK compatibility, and target-repo private registry credentials. |
| Prepare reports `mise` missing | Re-run `bin/install-macos-worker`; it restores the pinned `mise` that resolves repository version files. |
| Worker breaks after a Homebrew upgrade | It should not: nothing resolves through Homebrew. Re-run the installer to restore the pinned toolchain. |
| An agent executable is missing | Re-run the installer to restore the pinned Claude Code and Codex CLIs used by native worker Runs. |

## Why Pull Instead Of SSH

In k3s deployments, the Linux control plane should not need inbound SSH access
to every Mac mini. A pull updater works through the same outbound network path
the worker already needs for Syrus, keeps host-specific Xcode setup local to
the Mac, and lets each host activate a verified release atomically.
