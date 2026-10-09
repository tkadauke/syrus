# macOS worker updates

Native macOS workers use a pull-based updater instead of SSH-first
deployment. Each host runs `com.syrus.updater` under launchd. The updater
reads the same `/etc/syrus/worker.env` file as `com.syrus.worker`, polls
Syrus or `SYRUS_UPDATE_METADATA_URL` for desired release metadata, including
its hostname and worker storage identity when polling Syrus directly, and
activates releases locally.

Required metadata:

- `git_sha`: desired worker release SHA.
- `artifact_url`: URL for the `syrus-worker-macos-*.tar.gz` artifact.
- `artifact_sha256`: SHA-256 of the artifact.

Optional metadata:

- `version`, `full_git_sha`, `artifact_name`, and `built_at` for display.
- `retention_count` to bound rollback releases; default is `3`.
- `poll_interval_seconds` for the service loop; default is `300`.

The artifact is source-only. During activation the updater installs it under
`/opt/syrus/releases/<sha>`, runs host-local dependency setup (`bundle
install`, `npm ci`, and `bin/macos-worker-check`), atomically replaces
`/opt/syrus/current`, and restarts `system/com.syrus.worker` with
`launchctl kickstart -k`.

`SYRUS_DATA_ROOT`, worker storage identity, logs, credentials, shared bundle
cache, and environment remain outside release directories, so they survive
rollouts and rollbacks. Old release directories are pruned after activation
while keeping the active release and the configured rollback window.

Workers report update state to
`POST /api/v1/app/admin/macos_worker_update/report` with a scoped macOS worker
bearer token in `SYRUS_MACOS_WORKER_TOKEN`. Generate one with
`bin/rails syrus:macos_worker_token`; set `DAYS=<n>` to choose a lifetime
other than the default 30 days. The updater still accepts `SYRUS_API_TOKEN` as
a legacy fallback, but workers should not carry a human admin's full API token.
The live `InstanceVersion` row and retained
`WorkerHostHealthSample` rows include `desired_version`,
`macos_updater_status`, and `macos_updater_state`, allowing admin surfaces to
show `current`, `updating`, `failed`, or `stale` workers.

## Drain-aware rolling updates

Mac pool updates use `MacosWorkerDrain` rows keyed by worker storage identity
and hostname. A drain is separate from the role-wide restart poison pill:
draining or updating Mac workers remain alive for their active Runs and
spawned processes, but queue resolution stops counting them as compatible
capacity for new macOS/Xcode Runs. If every Mac worker is draining or
updating, Syrus blocks new Mac-capability Runs with the same no-capable-worker
vocabulary used for missing workers rather than advertising capacity that is
not currently claimable.

`POST /api/v1/app/admin/macos_worker_update/advance` advances one worker at a
time: select an outdated Mac worker, mark it draining, wait for active work to
settle, ask the updater to activate the desired `git_sha`, wait for a fresh
heartbeat at that SHA, verify the worker still advertises macOS and Xcode
capabilities, then complete the drain and move on to the next worker.

Repair affordances:

- `POST /api/v1/app/admin/macos_worker_update/drain` starts a drain for a
  specific `worker_storage_key` or `hostname`.
- `POST /api/v1/app/admin/macos_worker_update/clear` marks a stuck active drain
  completed.
- `POST /api/v1/app/admin/macos_worker_update/force_terminate` sets a force
  flag on the drain. The updater directive tells the host to restart even if
  active work remains; resulting worker deaths are classified as retryable
  Mac-update failures.

`GET /api/v1/app/admin/macos_worker_update` accepts `worker_storage_key` and
`hostname` query parameters. Its response includes a `drain` directive
(`none`, `draining`, `updating`, or `failed`) so a polling updater can tell the
difference between ordinary release metadata and an operator-requested rolling
update step. Desired release metadata is published for visibility, but
`enabled` is true only for the selected worker once its drain reaches
`updating` or an operator has requested forced termination.

This design avoids assuming the cluster can initiate SSH sessions into Mac
hardware. The k3s control plane only publishes desired release metadata and
receives status; each Mac host performs download, verification, activation,
and service restart from its own network and credential context.
