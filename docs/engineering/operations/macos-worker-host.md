# macOS worker host

This page covers one Mac host: what to prepare, how to install it, what is on
its disk, and what it must be able to reach. Updates are covered in
[macOS worker updates](macos_worker_updates.md), and failures in
[troubleshooting](macos-worker-troubleshooting.md). Read the
[hub](macos-workers.md) for the invariants these steps rely on.

## Prerequisites the operator owns

The installer cannot create these. Have them in place before it runs:

1. **Full Xcode**, selected with `xcode-select`, its license accepted, and the
   simulator runtimes the target repositories need.
2. **A fixed address** for the host, such as a DHCP reservation. The database
   LoadBalancer admits only listed source addresses.
3. **`/etc/syrus/worker.env`**, owned `root:syrus-worker` with mode `0640` (the
   installer re-applies this). It must hold dotenv assignments only. See
   [the env file contract](#env-file-contract).
4. **`/etc/syrus/macos-worker-update-public.pem`**, the public half of the
   deploy machine's release signing key (see
   [one-time setup](macos_worker_updates.md#one-time-setup)). The installer
   refuses to run without it. Without it the host would install fine and then
   never update.
5. **Signing identities.** Any keychain, certificates, provisioning profiles,
   and signing services the target repositories need, reachable by the
   `syrus-worker` launchd user without an interactive login.

Homebrew is not a prerequisite. The worker ignores it even if the host has it.

## Env file contract

`bin/macos-worker` sources the env file and then forces `RAILS_ENV`
(production by default), `SYRUS_ROLE=worker`,
`SOLID_QUEUE_CONFIG=config/queue.compute.yml`, `SOLID_QUEUE_SKIP_RECURRING=1`,
`SOLID_QUEUE_SHUTDOWN_TIMEOUT` (default 3540), bounded `DB_*_TIMEOUT`s, and the
Bundler settings from `syrus_macos_bundle_env` (including
`BUNDLE_WITHOUT=images`, which keeps libvips out of the process). `GIT_SHA` comes from the release's own `GIT_SHA`
file: a value in the env file is ignored, and a warning is logged. Do not set
`GIT_SHA` in the env file.

The env file must supply:

```dotenv
SYRUS_DATA_ROOT=/var/lib/syrus
SYRUS_APP_HOST=https://syrus.example.internal
SYRUS_WORKER_POOL_NAME=macos-xcode
SYRUS_WORKER_CAPABILITIES=os:macos,arch:arm64,toolchain:xcode,runtime:ios_simulator
SECRET_KEY_BASE=...
RAILS_MASTER_KEY=...            # or all three ACTIVE_RECORD_ENCRYPTION_* keys
DB_HOST=<database LoadBalancer address>
SYRUS_DATABASE_PASSWORD=...
S3_ENDPOINT=https://<object storage HTTPS host>
S3_ACCESS_KEY_ID=...
S3_SECRET_ACCESS_KEY=...
S3_BUCKET=...
SYRUS_MACOS_WORKER_TOKEN=...    # scoped updater token, see macos_worker_updates.md
```

These variables are required:

- `bin/macos-worker` refuses to start without the first four.
- `bin/macos-worker-check` also fails without `SECRET_KEY_BASE`, the
  encryption keys, and the DB and S3 settings (when `SYRUS_SQLITE` is set it
  skips the DB and S3 checks).
- The updater needs `SYRUS_MACOS_WORKER_TOKEN`. See
  [updater authentication](macos_worker_updates.md#how-the-updater-works).

GitHub and model credentials belong here only for a deployment that uses
process-level credentials rather than per-user encrypted ones.

## Install

From an unpacked worker release, or from a checkout at the revision to run:

```bash
sudo bin/install-macos-worker --env-file /etc/syrus/worker.env
```

It is idempotent: rerunning it brings the host in line with that release.
In order, it:

1. creates the `syrus-worker` user and group (first free uid/gid in
   450–499) and the root-owned and worker-owned directories;
2. copies the release into `/opt/syrus/releases/<sha>`, root-owned;
3. installs the release's pinned toolchain and the pinned agent CLIs;
4. runs `bundle install` (frozen) and `npm ci` as `syrus-worker`;
5. turns off interactive Git credential helpers for that account;
6. runs `bin/macos-worker-check`;
7. switches `/opt/syrus/current`, then installs the updater and its helper
   into `/usr/local/libexec/syrus`;
8. removes the retired tunnel LaunchDaemons, then bootstraps and kickstarts
   `com.syrus.worker` and `com.syrus.updater`.

Flags (`--help` has the full list):

- `--dry-run` prints the mutating commands without running them.
- `--skip-services` prepares the host without loading launchd.
- `--skip-dependencies` skips only the agent CLI install.
- `--env-file`, `--update-public-key`, `--install-root`, `--data-root`, and
  `--service-user` override the default paths and account.

After the first install, the updater keeps the host current. It also
reinstalls itself and its helper from each verified release. Rerun the
installer only in these cases:

- to repair a host;
- after a change the updater does not apply: new agent CLI pins, or a change
  to a launchd plist.

## Filesystem layout

| Path | Owner | Purpose |
| --- | --- | --- |
| `/opt/syrus/releases/<sha>` | root | Immutable release checkout. The worker cannot modify it |
| `/opt/syrus/current` | root | Symlink to the active release |
| `/opt/syrus/rubies/<version>`, `/opt/syrus/nodes/<version>` | root | Ruby and Node pinned by `.ruby-version` and `.node-version`, installed by mise as prebuilt binaries |
| `/opt/syrus/tools/mise/<version>` | root | Pinned mise binary |
| `/opt/syrus/tools/mysql-client/<version>` | root | Oracle's MySQL client library, with its own OpenSSL, that `mysql2` links against |
| `/opt/syrus/agent-clis` | root | npm prefix holding the pinned Claude Code and Codex CLIs |
| `/opt/syrus/shared/bundles/ruby-<ruby>-mysql-<client>` | worker | Bundler path shared by every release on that Ruby and client |
| `/opt/syrus/shared/node/<sha>` | worker | Each release's `node_modules`. The release's `node_modules` symlinks here |
| `/usr/local/libexec/syrus/syrus-macos-updater`, `.../macos-runtime-env` | root | The updater launchd runs, and the helper it sources, both outside the release tree |
| `/var/lib/syrus` | worker | `SYRUS_DATA_ROOT`: clone cache, `workflows/<id>`, `workflow-scratch/<id>`, `runtime-probes/`, `.syrus-worker-storage-id` |
| `/var/log/syrus/{worker,worker.err,updater,updater.err}.log` | worker | launchd stdout and stderr |
| `/etc/syrus/worker.env`, `/etc/syrus/macos-worker-update-public.pem` | root | Credentials and the release-verification key |

The first boot writes `.syrus-worker-storage-id`, and the compute queue
config then consumes that host's `resume-<worker-storage-key>` queue for
sticky retries. Deleting `/var/lib/syrus` while Runs are active forces fresh
checkouts and loses resume affinity. Syrus prunes workspaces on its own, and
the updater prunes old releases (see
[the retention window](macos_worker_updates.md#how-the-updater-works)).

## Pinned toolchain

Homebrew and `/usr/local` are shared with every other account on the host.
Upgrades there, even of a library a formula links against, have broken the
worker's Ruby, Node, and `mysql2`. Each release therefore pins its own
toolchain:

- Ruby and Node in `.ruby-version` and `.node-version` (the same versions the
  Linux image uses);
- mise and the MySQL client in `config/macos_worker_toolchain.env`, each with
  a URL and a SHA-256.

`bin/macos-runtime-env` is sourced by `bin/macos-worker`, by the installer,
and (as the installed copy) by the updater. It installs anything missing under
`/opt/syrus`, and builds a `PATH` from only the toolchain, the agent CLIs, and
the system directories. It also points Bundler at the matching shared bundle.
If any pinned piece is missing, the worker refuses to start rather than fall
back to the host's copy.

To bump a version, change the pin and deploy. The updater installs the new
version before it prepares the release, and the old one stays in place for
rollback. Agent CLI versions are pinned in `bin/install-macos-worker`, so a
bump there needs the installer rerun on each host.

## Network requirements

Each Mac needs outbound access to:

- MySQL, through an address-restricted LoadBalancer (`DB_HOST`);
- object storage, through its HTTPS endpoint (`S3_ENDPOINT`);
- the Syrus host in `SYRUS_APP_HOST`, over HTTPS (release metadata, the
  artifact, and status reports);
- GitHub and configured remotes, model provider APIs, and package registries;
- any private services the target repositories need for builds, tests,
  signing, or deploys.

Nothing connects inbound, and Syrus needs no SSH to the host. Do not
reintroduce `kubectl port-forward` tunnels. Their stalls and dropped
connections make Syrus declare the worker dead (see
[the pitfall](../pitfalls/macos-hosts.md#tunnelling-the-database-through-kubectl-port-forward)).

## Reinstall a host

Everything under `/opt/syrus` and `/usr/local/libexec/syrus` comes back from
the installer. On a wiped host:

1. Restore the [operator prerequisites](#prerequisites-the-operator-owns):
   Xcode, the fixed address, the env file, the public key, and the signing
   identities.
2. Issue a fresh `SYRUS_MACOS_WORKER_TOKEN`
   ([one-time setup](macos_worker_updates.md#one-time-setup)).
3. Run [the installer](#install) from a release at the currently active
   revision.
4. Run [the health check](macos-workers.md#health-check).

Keep a backup of the release signing private key. If it is lost, you must
generate a new pair and install the new public key on every Mac.

### Rehearse a restore

```bash
sudo bin/uninstall-macos-worker            # services, /opt/syrus, the updater
sudo bin/install-macos-worker --env-file /etc/syrus/worker.env
```

By default the uninstaller keeps everything the installer cannot recreate:
the env file, the public key, `/var/lib/syrus`, the logs, and the service
account. Rerunning the installer then brings back the same worker, with the
same storage identity. The uninstaller also removes the retired tunnel
services and never touches Homebrew.

Uninstaller flags:

- `--remove-data`, `--remove-account`, and `--remove-config` each remove one
  of the kept items. `--remove-config` also removes the retired
  `tunnel.kubeconfig`.
- `--all` does all three, for a true wipe.
- `--force` kills the worker instead of waiting up to an hour for in-flight
  Runs to drain.
- `--dry-run` prints what would be removed.

Return to the [macOS workers hub](macos-workers.md).
