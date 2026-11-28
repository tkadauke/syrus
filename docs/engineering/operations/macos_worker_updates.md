# macOS worker updates

How a Mac host moves from one release to the next. This page owns the
deploy phase, the signing key and worker token, the updater, the release
artifact, and the manual drain flow. Host setup lives in
[macOS worker host](macos-worker-host.md), and failures in
[troubleshooting](macos-worker-troubleshooting.md). Start at the
[hub](macos-workers.md).

## Every deploy updates the Mac workers

Mac workers run outside the cluster, so `bin/deploy` updates them as part of
every deploy that includes production (`Deploy::MacosWorkers`):

1. **Before any cluster changes**, it builds the source artifact for the
   commit being deployed (`bin/release-macos-worker`, pinned through
   `SYRUS_RELEASE_GIT_REF`), signs it, and uploads it
   (`POST /api/v1/admin/macos_worker_releases`). A missing signing key, admin
   token, or `SYRUS_APP_HOST` stops the deploy here, before any cluster has
   been touched.
2. **Right after production's migrations**, before any pod moves to the new
   image, it activates the release
   (`POST /api/v1/admin/macos_worker_releases/activate`). From then on, a Mac
   on another revision takes no new work: `RunQueueResolver` stops counting it
   as capacity, and `RunJob` hands back a Run it has already claimed, retrying
   every minute until the worker runs the active release.
3. **After every cluster has converged**, it polls
   `GET /api/v1/admin/macos_worker_releases/status` until every live Mac
   reports the revision. The wait is bounded by `MACOS_WORKER_UPDATE_TIMEOUT`
   (15 minutes by default) and checks every 10 seconds. The deploy fails if a
   Mac does not catch up or its updater reports `failed`. Nothing is rolled
   back: the cluster rollout stands, and the skew guard keeps the outdated Mac
   idle. A Mac seen in the last seven days but not heartbeating now is listed
   as offline and not waited for; it updates when it next polls.

An activated release has `rollout: immediate`, so every updater installs it
on its next poll; there is no drain. The updater reports `restarting` and then
restarts the worker. The old worker drains its in-flight Runs for up to an
hour ([graceful restarts](macos-workers.md#invariants)), and launchd then
starts it on the new release. While the old worker drains, the host counts as
updated, because its updater has activated the release and the skew guard
keeps new work away.

The deploy machine needs:

- `SYRUS_APP_HOST`, the production Syrus URL;
- an admin API token, `SYRUS_API_TOKEN` or `~/.config/syrus/api-token`;
- the signing key, `~/.config/syrus/macos-worker-update-signing.pem` or
  `SYRUS_MACOS_UPDATE_SIGNING_KEY_FILE`.

`SYRUS_DEPLOY_MACOS_WORKERS=0` skips the phase, for an installation without
Mac workers. The deploy-wide ordering is described in
[deploying Syrus](deploying-syrus.md#macos-workers).

## One-time setup

**Signing keypair.** Generate it on the machine you deploy from and keep the
private key there, backed up. Install only the public key on each Mac:

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

**Worker token.** In production, run `bin/rails syrus:macos_worker_token`
(`DAYS=<n>` sets the lifetime; the default is 30). Put the result in each
host's `/etc/syrus/worker.env` as `SYRUS_MACOS_WORKER_TOKEN`. The token is
scoped to the updater endpoints. The updater still accepts `SYRUS_API_TOKEN`
as a legacy fallback, but a host should never carry a person's full admin
token. When the token expires, the host stops updating. Issue a new one before
then.

The host also needs a worker installed with
[`bin/install-macos-worker`](macos-worker-host.md#install).

## How the updater works

`com.syrus.updater` runs `/usr/local/libexec/syrus/syrus-macos-updater` as
root and reads the same env file as the worker. On each poll it:

1. fetches `GET /api/v1/app/admin/macos_worker_update`, sending its hostname
   and worker storage key, from `SYRUS_APP_HOST`
   (`SYRUS_UPDATE_METADATA_URL` overrides the URL);
2. stops if `enabled` is false, if the drain directive holds it back (see
   [below](#drain-aware-manual-updates)), or if it already runs `git_sha`;
3. downloads `artifact_url`, which by default is
   `GET /api/v1/app/admin/macos_worker_update/artifact` on Syrus itself, with
   the same token;
4. verifies the detached RSA/SHA-256 `artifact_signature` against
   `/etc/syrus/macos-worker-update-public.pem`, then the `artifact_sha256`;
5. unpacks it root-owned into `/opt/syrus/releases/<sha>` and installs any
   toolchain the release pins that the host lacks
   ([pinned toolchain](macos-worker-host.md#pinned-toolchain));
6. as `syrus-worker`, runs `bundle install` (frozen), `npm ci`, and
   `bin/macos-worker-check`;
7. reinstalls itself and its helper from the release, switches
   `/opt/syrus/current` atomically, reports `restarting`, and runs
   `launchctl kickstart -k system/com.syrus.worker`;
8. prunes old releases, keeping the active one plus a rollback window
   (`retention_count`, default 3), then reports `current`.

Both metadata and artifact downloads require HTTPS. `file://` URLs work only
with the test override `SYRUS_MACOS_UPDATE_ALLOW_FILE_URLS=1`. The poll
interval comes from the metadata: Syrus sends 60 seconds for an activated
release, and the fallback is 300.

At every stage the updater posts its state (`updating`, `restarting`,
`current`, or `failed`, with a message) to
`POST /api/v1/app/admin/macos_worker_update/report`. Syrus stores it on the
worker's `InstanceVersion` (`macos_updater_status`, `desired_version`). The
deploy's status check and the admin worker views read it from there.

`SYRUS_DATA_ROOT`, the storage identity, logs, credentials, and the shared
bundle and node trees all live outside release directories, so they survive
rollouts and rollbacks.

### Release artifact

`bin/release-macos-worker [VERSION]` produces the artifact
`syrus-worker-macos-arm64-<git_sha>.tar.gz`, plus `SHA256SUMS-macos-worker.txt`.
When `SYRUS_MACOS_UPDATE_SIGNING_KEY_FILE` is set, it also writes a `.sig`.
The archive is source only:

- it contains the tracked app source, the Mac binstubs, the launchd plists,
  the lockfiles, `GIT_SHA`, `SYRUS_VERSION`, and
  `config/syrus-worker-release.json`;
- it never contains native gems, `node_modules`, workspaces, or logs, which
  each host builds during activation.

Syrus stores uploaded releases in Active Storage under
`macos-worker/releases/<sha>` (`MacosWorkerRelease`).

## Drain-aware manual updates

The drain flow updates one host at a time, by hand. Deploys do not use it.
A `MacosWorkerDrain` row, keyed by worker storage key and hostname, removes
that host from compatible capacity while it finishes its active Runs. It is
separate from the role-wide restart. If every Mac is draining or updating, new
Mac-capability Runs block as `no_capable_worker`.

All the endpoints are under `/api/v1/app/admin/macos_worker_update`:

- `POST .../advance` takes the next outdated Mac through the whole cycle: it
  marks the host draining, waits for its work to settle, lets the updater
  install the desired `git_sha`, waits for a fresh heartbeat at that SHA, and
  checks that the host still advertises macOS and Xcode.
- `POST .../drain` starts a drain for one `worker_storage_key` or `hostname`.
- `POST .../clear` marks a stuck drain completed.
- `POST .../force_terminate` tells the updater to restart even with work
  still running. Runs it kills are classified as retryable Mac-update
  failures.

How the metadata response decides whether a host updates:

- **`enabled`** is true when the desired release is complete and either its
  `rollout` is `immediate` (every release a deploy activates) or this host's
  drain permits the update.
- **`drain`** is one of `none`, `draining`, `updating`, or `failed`. The
  updater holds back only while the drain is in some state other than `none`
  or `updating` and has not been forced. A deploy's release, which has drain
  `none`, is therefore never held back.

Return to the [macOS workers hub](macos-workers.md).
