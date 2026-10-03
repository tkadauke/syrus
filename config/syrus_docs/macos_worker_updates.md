# macOS worker updates

Native macOS workers use a pull-based updater instead of SSH-first
deployment. Each host runs `com.syrus.updater` under launchd. The updater
reads the same `/etc/syrus/worker.env` file as `com.syrus.worker`, polls
Syrus or `SYRUS_UPDATE_METADATA_URL` for desired release metadata, and
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
`POST /api/v1/app/admin/macos_worker_update/report` with an admin bearer token
in `SYRUS_API_TOKEN`. The live `InstanceVersion` row and retained
`WorkerHostHealthSample` rows include `desired_version`,
`macos_updater_status`, and `macos_updater_state`, allowing admin surfaces to
show `current`, `updating`, `failed`, or `stale` workers.

This design avoids assuming the cluster can initiate SSH sessions into Mac
hardware. The k3s control plane only publishes desired release metadata and
receives status; each Mac host performs download, verification, activation,
and service restart from its own network and credential context.
