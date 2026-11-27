# macOS host pitfalls

Traps for anyone who changes `bin/macos-worker`, `bin/macos-runtime-env`,
`bin/install-macos-worker`, `bin/uninstall-macos-worker`,
`bin/syrus-macos-updater`, or the code paths that serve them. Each one has
bitten a production host. The scripts run on macOS only, so Linux CI does not
catch these traps; the `spec/bin/*macos*` specs do. The inventory is in
[the macOS workers map](../maps/macos-workers.md), and operations start at
[the hub](../operations/macos-workers.md).

## BSD `mv` follows a destination symlink

**Symptom:** after an install or update, `/opt/syrus/current` still points
at the old release, and a `current.next` link appears inside that release.
**Cause:** when the destination is a symlink to a directory, BSD `mv -f` moves
the source *into* that directory. **Prevention:** replace the link itself.
The installer uses `mv -h -f`, and the updater uses Ruby `File.rename`
(`activate_release`). Never write a plain `mv` onto `current`.

## `/var` is `/private/var`

**Symptom:** the updater prunes the release it just activated, which leaves
`current` dangling. Separately, Claude resume finds no transcripts for
workspaces under `/var/lib/syrus`. **Cause:** `pwd -P` and the OS-reported
cwd resolve `/var` to `/private/var`, while `find` and stored paths keep the
unresolved prefix, so equality checks never match. **Prevention:** compare
paths only after resolving both sides. See `prune_releases` in
`bin/syrus-macos-updater`, `ClaudeAgent::SessionPaths.encoded_project`, and
`ImmutableSourceCheckout`.

## bash 3.2 and empty arrays under `set -u`

**Symptom:** every `curl` in the updater aborts with
`CURL_AUTH_ARGS[@]: unbound variable`. **Cause:** macOS ships bash 3.2, where
expanding an empty array under `set -u` is an error. Bash 4.4+ on Linux
accepts it, so specs run on Linux miss it. **Prevention:** expand optional
arrays as `${ARR[@]+"${ARR[@]}"}`, and test the empty case.

## Bundler rewriting a root-owned lockfile

**Symptom:** `bundle install` fails during activation while trying to write
`Gemfile.lock`. **Cause:** a Bundler newer than the lockfile's `BUNDLED WITH`
rewrites the lockfile, and the release tree is root-owned. **Prevention:**
every install runs with `BUNDLE_FROZEN=true` (installer and updater).

## Precompiled native gems on a frozen install

**Symptom:** a frozen `bundle install` fails on an arm64 Mac for a gem that
installs fine on Linux. **Cause:** the precompiled darwin build does not
support the pinned Ruby, and frozen mode refuses to fall back to the source
gem. **Prevention:** mark the gem `force_ruby_platform: true` in the
`Gemfile`, as was done for `bcrypt_pbkdf`.

## Anything from Homebrew or `/usr/local`

**Symptom:** after an unrelated `brew upgrade`, the worker's Ruby, Node, or
`mysql2` fails to load. **Cause:** Homebrew is shared with every account on
the host and upgrades its libraries in place. **Prevention:** resolve
everything through `bin/macos-runtime-env`. Keep the plist `PATH` at
`/usr/bin:/bin:/usr/sbin:/sbin`, and keep `SYRUS_LIBVIPS=disabled`. A new
native dependency gets a pin in `config/macos_worker_toolchain.env` with a
SHA-256, never a `brew install`. `bin/macos-worker-check` fails if `PATH`
contains Homebrew.

## Running release code as root before it is verified

**Symptom:** none, until someone uploads a malicious release. **Cause:** the
updater runs as root, so sourcing a helper from the downloaded tree, or
executing its pin file, would run unverified code. **Prevention:** the updater
sources its own installed `macos-runtime-env`.
`syrus_macos_toolchain_value` *parses* `config/macos_worker_toolchain.env`
rather than sourcing it. Signature verification comes before anything else
touches the artifact.

## Holding a deploy's release behind the drain directive

**Symptom:** a deploy times out waiting for every Mac, and the updaters log
nothing new. **Cause:** Syrus always sends a `drain` directive, and its state
is `none` for an immediate release. An updater that treated any directive as
a hold never updated. **Prevention:** hold only while the drain state is
something other than `none` or `updating` and has not been forced
(`extract_metadata` in the updater). Keep `enabled` true for
`rollout: immediate` (`MacosWorkerUpdatesController#desired_payload`).

## Trusting `GIT_SHA` from the env file

**Symptom:** a host reports a revision it is not running, so the skew guard
either idles a current host or admits a stale one. **Cause:** an env-file
`GIT_SHA` from an earlier manual install outlived the releases.
**Prevention:** `bin/macos-worker` takes the revision from the release's
`GIT_SHA` file and ignores the env value.

## Building the release from `HEAD` during a deploy

**Symptom:** the Mac release carries a different commit from the cluster.
**Cause:** another session committed while the deploy was running.
**Prevention:** the deploy passes `SYRUS_RELEASE_GIT_REF=<deploy sha>` to
`bin/release-macos-worker`, which then packages from git, not from the working
tree.

## Tunnelling the database through `kubectl port-forward`

**Symptom:** queries hang forever, MCP tool calls time out, and then Syrus
declares the worker dead and discards in-flight work. **Cause:** a
port-forward relays every connection over one API-server stream that stalls
and drops connections without resetting the local socket. **Prevention:**
connect directly (see
[network requirements](../operations/macos-worker-host.md#network-requirements)).
The installer and uninstaller remove the retired tunnel services, and
`bin/macos-worker` bounds every DB socket operation (`DB_*_TIMEOUT`) so a dead
connection fails instead of hanging.

## A shutdown budget longer than launchd's

**Symptom:** updates SIGKILL in-flight Runs. **Cause:** launchd kills a job
that is still running at `ExitTimeOut`. **Prevention:** keep
`SOLID_QUEUE_SHUTDOWN_TIMEOUT` (3540, in `bin/macos-worker`) below the worker
plist's `ExitTimeOut` (3600), and change both together.

## Running the services as `Background` launchd jobs

**Symptom:** whenever another account builds on the host, the worker's
heartbeats lapse and updates take many minutes to unpack a release. **Cause:**
launchd runs `ProcessType` `Background` jobs at the lowest CPU priority with
throttled disk I/O, below any interactive build. **Prevention:** both plists
in `config/launchd/` use `Standard`; `spec/bin/macos_worker_spec.rb` guards
it. Plist changes reach a host only through `bin/install-macos-worker` (see
[when to rerun the installer](../operations/macos-worker-host.md#install)).

Return to the [pitfalls index](README.md).
