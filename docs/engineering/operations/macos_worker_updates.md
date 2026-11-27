# macOS worker updates

## Every deploy updates the Mac workers

Mac workers run outside the cluster, so `bin/deploy` updates them as part of
every deploy that includes production (`Deploy::MacosWorkers`):

1. **Before any cluster changes**, it builds the source artifact for the
   revision being deployed (`bin/release-macos-worker`), signs it with the
   release signing key, and uploads it to the production Syrus
   (`POST /api/v1/admin/macos_worker_releases`). A missing key,
   token, or `SYRUS_APP_HOST` stops the deploy here, with every cluster
   untouched.
2. **Right after production's migrations**, before any pod is pinned to the
   new image, it activates the release
   (`POST /api/v1/admin/macos_worker_releases/activate`). From then on, a Mac worker on
   another revision takes no new work: `RunQueueResolver` stops counting it as
   capacity, and a Run it has already claimed is handed back by `RunJob`
   until it runs the active release.
3. **After every cluster has converged**, it waits for each live Mac worker to
   report the revision (`GET /api/v1/admin/macos_worker_releases/status`, bounded by
   `MACOS_WORKER_UPDATE_TIMEOUT`, 15 minutes by default). A Mac worker that does
   not catch up, or whose updater reports a failure, fails the deploy. Nothing
   is rolled back: the cluster rollout stands, and the skew guard keeps the
   outdated Mac worker idle until it updates. Mac workers that are offline are
   listed but not waited for; they update when they next poll.

An activated release rolls out immediately rather than through the drain flow
below. The updater installs it and restarts the worker, which drains its
in-flight runs on SIGTERM for up to an hour (`SOLID_QUEUE_SHUTDOWN_TIMEOUT`,
within the launchd `ExitTimeOut`), the same budget compute pods get. The
updater reports the activation before that restart, and a host whose updater
has activated the release counts as updated while its old worker drains.

Syrus serves the artifact itself (`GET /api/v1/app/admin/macos_worker_update/artifact`), over
the same HTTPS host and scoped `SYRUS_MACOS_WORKER_TOKEN` the updater already
uses, so Mac hosts need no other download source.

The deploy needs `SYRUS_APP_HOST` (the production Syrus URL), an admin API
token (`SYRUS_API_TOKEN`, or `~/.config/syrus/api-token`), and the release
signing key (`~/.config/syrus/macos-worker-update-signing.pem`, or
`SYRUS_MACOS_UPDATE_SIGNING_KEY_FILE`). `SYRUS_DEPLOY_MACOS_WORKERS=0` skips the
phase, for an installation without Mac workers.

### One-time setup

Generate the signing keypair on the machine you deploy from, keep the private
key there, and install the public key on every Mac worker host:

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
  -out ~/.config/syrus/macos-worker-update-signing.pem
chmod 600 ~/.config/syrus/macos-worker-update-signing.pem
openssl pkey -in ~/.config/syrus/macos-worker-update-signing.pem -pubout \
  -out macos-worker-update-public.pem
# on each Mac host:
sudo install -o root -g wheel -m 644 macos-worker-update-public.pem \
  /etc/syrus/macos-worker-update-public.pem
```

The Mac host also needs `SYRUS_MACOS_WORKER_TOKEN` in `/etc/syrus/worker.env`
(see below) and a worker installed with `bin/install-macos-worker`.

## How the updater works

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
- `artifact_signature`: base64-encoded RSA/SHA-256 detached signature of the
  artifact.

Optional metadata:

- `version`, `full_git_sha`, `artifact_name`, and `built_at` for display.
- `retention_count` to bound rollback releases; default is `3`.
- `poll_interval_seconds` for the service loop; default is `300`.

The artifact is source-only. The updater requires HTTPS for metadata and
artifact downloads, verifies the detached signature against the independently
provisioned `/etc/syrus/macos-worker-update-public.pem`, and then checks the
SHA-256 digest. `file://` transport is disabled unless the explicit
`SYRUS_MACOS_UPDATE_ALLOW_FILE_URLS=1` test override is present.

During activation the updater installs the release root-owned and non-writable
by the worker under `/opt/syrus/releases/<sha>`. It installs any part of the
toolchain the release pins that the host does not have yet -- mise and the
MySQL client from `config/macos_worker_toolchain.env`, Ruby and Node from
`.ruby-version` and `.node-version` -- under `/opt/syrus`, never from
Homebrew. It then runs host-local dependency
setup (`bundle install` into that toolchain's bundle, `npm ci`, and
`bin/macos-worker-check`) as the `syrus-worker` account, atomically replaces
`/opt/syrus/current`, and restarts `system/com.syrus.worker` with
`launchctl kickstart -k`.

The privileged updater itself is installed root-owned at
`/usr/local/libexec/syrus/syrus-macos-updater`; launchd never executes updater
code from the worker release tree. To produce a signature alongside a release,
set `SYRUS_MACOS_UPDATE_SIGNING_KEY_FILE` when running
`bin/release-macos-worker`, then put the generated `.sig` contents in the
desired release's `artifact_signature`. Keep that private key off worker hosts;
provision only its public key at the pinned path above.

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
