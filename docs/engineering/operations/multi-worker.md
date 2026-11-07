# Multi-worker operations

## Spreading workers across nodes (queue partitioning)

The search index is SQLite FTS5 on a single-node RWO volume, so the queues that
touch it can't spread. To run agent compute on multiple nodes anyway, split the
queues across two worker configs and select one per pod with the
`SOLID_QUEUE_CONFIG` env var:

| Config | Queues | Where |
| --- | --- | --- |
| `config/queue.home.yml` | `chat`, `videos`, `control_plane`, `polling`, `indexing`, `cleanup`, `low_priority_maintenance` (+ its `resume-<worker-storage-key>`) | one pod, on the node holding the search PVC / with the web pods |
| `config/queue.compute.yml` | `runs`, `merges` (+ its `resume-<worker-storage-key>`) | one pod per worker node; local disk, no search mount |

- **The home worker** runs everything bound to the single-node search index or
  co-located with it: `control_plane`, `polling`, `indexing` (search
  **writes**), `cleanup`, `low_priority_maintenance`, `chat` (search **reads**
  via the `search_chats` MCP tool), and `videos`. It is the tier that schedules
  recurring tasks — leave `SOLID_QUEUE_SKIP_RECURRING` unset here.
- **The compute worker** runs the heavy, search-free queues — `runs`
  (implementation, response, grader, and `main_grader` RunJobs) and `merges`
  (landing / rebase) — which enqueue their search updates onto `indexing` rather
  than touching the index directly. Spread it one-per-node on fast local disk.
  Set `SOLID_QUEUE_SKIP_RECURRING=1` so only the home worker schedules recurring
  jobs.
- Both configs consume the current data root's `resume-<worker-storage-key>`
  queue, so retry-from-failed-step affinity (below) works on whichever worker
  can see the workspace.

## Native macOS compute workers

Native macOS workers are supported as external **compute** workers for Xcode,
iOS simulator, and other host-native work that cannot run inside Linux k3s.
They are not Kubernetes nodes, and they must not consume chat, polling,
indexing, cleanup, or control-plane queues.

In a k3s production topology, keep web, the single home worker, Linux compute,
MySQL, object/artifact storage, ingress, and search/data volumes in Linux or
managed infrastructure. Attach Mac minis as outbound external workers under
launchd. A Linux VM on Mac hardware may join k3s as Linux capacity, but it is
not a substitute for native Xcode/simulator execution.

Example hybrid layout:

| Tier | Location | Queue/role boundary |
| --- | --- | --- |
| Web | k3s | HTTP app, API, admin UI, metrics |
| Home worker | one k3s pod | `chat`, `polling`, `indexing`, `cleanup`, `control_plane`, `videos`, home resume queue |
| Linux compute | k3s pods | `runs`, `runs-linux-amd64`, `merges`, `merges-linux-amd64`, local resume queue |
| Mac mini pool | external launchd | `runs-macos-arm64`, `merges-macos-arm64`, compatible `resume-<worker-storage-key>` queues |
| Data services | k3s or managed | MySQL, storage, release artifacts, search/data volumes |

Mac workers need outbound access to the production database, object/artifact
storage if used, the Syrus app/API host, GitHub and configured remotes, model
provider APIs, package registries, release artifact storage, and any internal
services the target repositories require for builds, tests, signing, or
deploys. The cluster should not need inbound SSH to the Mac pool for normal
operation.

The supported entrypoint is:

```bash
/opt/syrus/current/bin/macos-worker --env-file /etc/syrus/worker.env
```

`bin/macos-worker` sources the env file, then forces the role and queue
partition that make the process a compute-only worker:

```dotenv
RAILS_ENV=production
SYRUS_ROLE=worker
SOLID_QUEUE_CONFIG=config/queue.compute.yml
SOLID_QUEUE_SKIP_RECURRING=1
SYRUS_DATA_ROOT=/var/lib/syrus
SYRUS_APP_HOST=syrus.example.internal
SYRUS_WORKER_POOL_NAME=macos-xcode
SYRUS_WORKER_CAPABILITIES=os:macos,arch:arm64,toolchain:xcode,runtime:ios_simulator
GIT_SHA=<release sha>
```

If `GIT_SHA` is absent, the wrapper derives it from the release checkout with
`git rev-parse --short HEAD`; immutable package installs should set it
explicitly. The same env file must also contain the normal production Rails
credentials: `SYRUS_APP_HOST`; `SECRET_KEY_BASE`; either `RAILS_MASTER_KEY` or all three
`ACTIVE_RECORD_ENCRYPTION_*` keys; MySQL settings such as `DB_HOST` and
`SYRUS_DATABASE_PASSWORD` unless this is a SQLite local-mode install; and S3 or
MinIO attachment credentials (`S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`,
`S3_BUCKET`, `S3_ENDPOINT`) unless `SYRUS_SQLITE` is set.
Include `SYRUS_MACOS_WORKER_TOKEN` when the updater polls Syrus directly or
reports activation state. If the installation uses private artifact storage, include
the credentials and trust material needed to download and verify the worker
release archive. GitHub and model credentials belong in the env file only when
the deployment intentionally uses process-level credentials rather than
per-user encrypted credentials.

Release builds publish a source artifact named
`syrus-worker-macos-arm64-<git_sha>.tar.gz` with
`SHA256SUMS-macos-worker.txt`. The archive contains the tracked app source,
`bin/macos-worker`, `bin/macos-worker-check`, `config/launchd/com.syrus.worker.plist`,
Gemfile and lockfiles, package manifests, `GIT_SHA`, `SYRUS_VERSION`, and
`config/syrus-worker-release.json` metadata. It deliberately does not bundle
native gems, npm installs, workflow workspaces, logs, storage, or local release
output; activation on each Mac installs host-specific dependencies into the
shared paths below. Verify the checksum before switching `/opt/syrus/current`.
Mac workers must not run database migrations. Deploy the k3s cluster first,
let it run migrations, and only then roll Mac workers onto a schema-compatible
artifact.

Before enabling launchd, run:

```bash
/opt/syrus/current/bin/macos-worker-check --env-file /etc/syrus/worker.env
```

The check does not boot Rails or start Solid Queue. It validates Ruby/Bundler,
Node/npm, Git, Xcode Command Line Tools, full Xcode selection, available simulator
runtimes, the macOS worker env contract, and production credentials. It exits
nonzero with `FAIL` lines for missing requirements, so it is safe for release
cutover scripts.

A launchd template lives at `config/launchd/com.syrus.worker.plist`. Install it
as a root-managed LaunchDaemon after creating a dedicated unprivileged user:

```bash
SYRUS_WORKER_ID=450 # choose an unused local uid/gid for this host
sudo dscl . -create /Groups/syrus-worker
sudo dscl . -create /Groups/syrus-worker PrimaryGroupID "$SYRUS_WORKER_ID"
sudo dscl . -create /Users/syrus-worker
sudo dscl . -create /Users/syrus-worker UniqueID "$SYRUS_WORKER_ID"
sudo dscl . -create /Users/syrus-worker PrimaryGroupID "$SYRUS_WORKER_ID"
sudo dscl . -create /Users/syrus-worker UserShell /usr/bin/false
sudo dscl . -create /Users/syrus-worker NFSHomeDirectory /var/lib/syrus

sudo mkdir -p /opt/syrus/releases /opt/syrus/shared /var/lib/syrus /var/log/syrus /etc/syrus
sudo chown -R root:wheel /opt/syrus
sudo chown -R syrus-worker:syrus-worker /opt/syrus/shared /var/lib/syrus /var/log/syrus
sudo chmod 750 /var/lib/syrus /var/log/syrus
sudo chown root:syrus-worker /etc/syrus/worker.env
sudo chmod 640 /etc/syrus/worker.env

sudo install -o root -g wheel -m 644 /opt/syrus/current/config/launchd/com.syrus.worker.plist /Library/LaunchDaemons/com.syrus.worker.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.syrus.worker.plist
sudo launchctl kickstart -k system/com.syrus.worker
```

The expected filesystem layout is:

| Path | Purpose |
| --- | --- |
| `/opt/syrus/releases/<sha>` | root-owned, immutable release checkout; the worker cannot modify privileged code |
| `/opt/syrus/current` | symlink to the active release |
| `/opt/syrus/shared/bundle` | Bundler install path reused by releases |
| `/usr/local/libexec/syrus/syrus-macos-updater` | root-owned updater executed by launchd, outside the release tree |
| `/var/lib/syrus` | `SYRUS_DATA_ROOT`: clone cache, workflow workspaces (`workflows/<workflow_id>`), per-workflow grader scratch beside them (`workflow-scratch/<workflow_id>`: grader checkouts, prepare caches, archive staging), version/capability probe scratch (`runtime-probes/`), search SQLite file if configured there, and `.syrus-worker-storage-id` |
| `/var/log/syrus/worker.log` / `worker.err.log` | launchd stdout/stderr logs |
| `/etc/syrus/worker.env` | root-owned env file with app, DB, storage, and worker capability credentials |

Release cleanup should keep the current release, at least one rollback release,
and any release that still has a running `bin/jobs` process. Workspace cleanup
is handled by Syrus through normal per-worker pruning; do not delete
`/var/lib/syrus` while Runs are active unless you intend to force fresh
checkouts and lose resume affinity.

`InstanceVersionSupervisor` and `RestartWatcher` behave like they do in
containers because the entrypoint uses `SYRUS_ROLE=worker` and `bin/jobs`.
Admin restart remains role-wide: a worker restart request can terminate every
worker-role process, including native macOS workers, so rolling pool updates
should still use launchd drain/restart procedure rather than relying on the
admin button alone.

Worker storage identity is fully supported on macOS. The first boot writes
`$SYRUS_DATA_ROOT/.syrus-worker-storage-id`, and the compute queue config
consumes the matching `resume-<worker-storage-key>` queue for sticky retries.

Known telemetry gap: `WorkerHostHealthSampler` currently reads Linux `/proc`
files for CPU, memory, and load metrics. On Linux workers, pressure metrics
prefer the worker's cgroup v2 `cpu.pressure`/`io.pressure` files and fall back
to `/proc/pressure/*` only when the cgroup files are absent; the sample's
`raw_metrics` records which source/path was used. On macOS those fields are
reported as absent rather than synthesized. Data-root disk usage, worker
capabilities, version, role, hostname, storage key, Solid Queue heartbeats, and
health sample rows still record normally, so the worker is visible in admin
surfaces even though Linux pressure charts are empty.

### Native macOS worker troubleshooting

When a macOS-capability Workflow is blocked with no capable worker, check Admin
Workers or `read_queue` for a fresh Mac worker heartbeat, matching
`os:macos` capability, and consumption of `runs-macos-arm64` or the expected
`resume-<worker-storage-key>` queue. A drained or updating Mac worker is
intentionally excluded from compatible capacity until the update completes.

If the worker version is stale, inspect updater status on the worker-health
surface, confirm `SYRUS_MACOS_WORKER_TOKEN` can read desired release metadata,
verify the artifact URL and SHA-256, and compare the worker's heartbeat
`git_sha` with the desired release. Mac workers should be rolled only after the
k3s/web deployment has run migrations.

If `bin/macos-worker-check --env-file /etc/syrus/worker.env` reports Xcode
failures, fix Command Line Tools or `xcode-select`, install full Xcode, accept
the Xcode license, and install the required simulator runtimes. Missing
simulators are reported by the worker check and capability diagnostics; workers
advertise `runtime:ios_simulator` only when the simulator probe succeeds.

For Keychain and signing failures, validate the launchd user rather than an
interactive admin shell: the worker user must be able to unlock or access the
signing keychain, certificates, provisioning profiles, and any internal signing
or notarization services required by the target repository.

**The home worker MUST be a single pod** (`replicas: 1`, `strategy: Recreate`).
Chat workspaces (`ChatWorkspace`, at
`$SYRUS_DATA_ROOT/chat-workspaces/<chat_session_id>`) are local-disk and
long-lived, and — unlike Workflows — chat has **no** pod-affinity mechanism.
`chat_sessions` records no `worker_hostname`; while a coding checkout is on
disk, `ensure_coding_checkout!` returns that local checkout instead of re-cloning
on another pod. A chat session's turns therefore MUST all land on the same pod,
which holds only because exactly one pod consumes `chat`. Never put `chat` on
the compute DaemonSet, and never scale the home worker past one replica. (If the
chat tier ever needs to scale, chat first needs its own storage-affinity queue
keyed off `chat_sessions.workspace_path` or equivalent durable workspace owner.)
Coding-mode **handoff** is exempt: `submit_coding_changes` captures the current
HEAD to an immutable handoff branch after confirmation, and attached-Job
`complete_implement_step` captures the current checkout HEAD to the appropriate
handoff branch after confirmation before handing work to the `coding_handoff`
workflow. Once the workflow starts, it owns any further repair and publication
work from a normal workflow checkout, so it runs safely on any compute pod.

## Per-worker disk health

Each worker fills its own data volume independently, so disk health is per-pod.
Worker pods stamp their own `SYRUS_DATA_ROOT` usage onto their `InstanceVersion`
row every heartbeat (`df`, worker role only — web pods don't mount the volume).
The "Worker data volume usage" banner and the admin overview surface the
**most-full** worker (`InstanceVersion.worst_data_root`), naming the pod, and
fall back to the single cached snapshot on single-worker / dev. The banner's
remediation copy branches on deployment: single-host Docker (Compose / the
desktop apps, detected via `SYRUS_SQLITE`) gets `docker image prune` guidance
because the volume shares the Docker host's disk; K8s gets per-pod workspace and
volume-resize guidance instead.

### Docker Compose CPU sizing

Docker Desktop, OrbStack, and Colima may expose no cgroup CPU quota inside the
worker container. For installs managed by `install.sh`, the installer records
the Docker VM's CPU count as `SYRUS_WORKER_CPU_LIMIT` in `.env` the first time
the key is missing or blank. Because `docker-compose.yml` supplies that file to
the shared app configuration, the worker receives it without extra wiring.

If worker capacity is unexpectedly low or Runs remain blocked with
`host_resource_semaphore_busy`, check that `SYRUS_WORKER_CPU_LIMIT` is a
positive integer appropriate for the VM, then restart the worker. The installer
never replaces a nonblank operator value when the VM size changes. Manual
Compose setups can add the same key to `.env` themselves.

Manual Job pause is operator-controlled and is not an admission-control signal.
It persists on the Job (`manual_paused`) and takes effect at the next Step
boundary: the current Run finishes, then the dispatcher records
`pause_reason: manual_pause` on the Workflow and does not enqueue another Run.
Manual pauses have no automatic `next_check_at`; only an operator unpause clears
the flag and lets normal admission/dependency/provider checks decide when the
workflow can proceed.
