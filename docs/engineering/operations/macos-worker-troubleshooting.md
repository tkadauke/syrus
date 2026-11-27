# macOS worker troubleshooting

Each entry gives the symptom, how to confirm it, the cause, and the fix. Run
[the hub's health check](macos-workers.md#health-check) first: most entries
start from its output. The commands that apply in each case are named below.

Two definitions used throughout:

- **Host shell** is a shell on the Mac.
- **Admin API** means
  `curl -H "Authorization: Bearer $SYRUS_API_TOKEN" "$SYRUS_URL/api/v1/admin/…"`
  (see the [syrus-debug skill](../../../.claude/skills/syrus-debug/SKILL.md)).

## A macOS Workflow is blocked with `no_capable_worker`

- **Confirm:** check the Workflow's `start_blocked_details` and
  `run_queue_admission_decision`. Then check `GET /queue/workers` for a fresh
  Mac heartbeat, `os:macos` among its capabilities, and `runs-macos-arm64` among
  its queues.
- **Cause, and fix, by case:**
  - *No fresh heartbeat:* the worker is down. See
    [the worker does not start](#the-worker-does-not-start-or-keeps-restarting).
  - *The heartbeat is fresh but the version differs from `desired_git_sha`:*
    this is version skew. See
    [the next entry](#a-mac-takes-no-work-after-a-deploy).
  - *`SYRUS_WORKER_CAPABILITIES` is missing a dimension:* fix the env file
    and kickstart the worker.
  - *`runtime:ios_simulator` is missing:* the simulator probe failed. See
    [Xcode or simulator failures](#xcode-or-simulator-failures).
  - *Every Mac is draining or updating:* wait, or
    [clear a stuck drain](#a-drain-never-finishes).
  - *The Job was planned for Linux:* continue it through a capable-worker
    path; the mutable workspace never migrates
    ([iOS compute](ios-compute.md#inspect-missing-capability-blockers)).

## A Mac takes no work after a deploy

- **Confirm:** in `GET /macos_worker_releases/status`, the host shows
  `current: false`. The Run's log shows `macOS worker runs <sha>, but the
  active release is <sha>; waiting for the update`.
- **Cause:** this is the skew guard, which is working as intended. The host
  has not installed the active release yet.
- **Fix:** read `updater_state` and `updater_message` in the same response:
  - *`failed`:* see
    [the updater reports failed](#the-updater-reports-failed);
  - *empty, or stale for minutes:* see
    [the updater never updates](#the-updater-never-updates).

## The deploy fails in the macOS workers phase

- **Confirm:** the deploy prints one of these messages:
  - `update failed on <host>`, with the updater message as the detail;
  - `not finished after … waiting for <host>`;
  - a prerequisites error that names `SYRUS_APP_HOST`, the API token, or
    the signing key.
- **Cause:** the host's update failed, the host is slow (for example, a
  long first `bundle install` after a Ruby bump), or the deploy machine lacks
  its credentials.
- **Fix:** nothing needs rolling back
  ([deploy phase](macos_worker_updates.md#every-deploy-updates-the-mac-workers)).
  - Fix the host using the entries on this page; it then updates on its next
    poll.
  - For missing prerequisites, restore them on the deploy machine and
    redeploy.

## The updater reports `failed`

- **Confirm:** run `tail -n 100 /var/log/syrus/updater.log
  /var/log/syrus/updater.err.log` in a host shell. The last
  `syrus-macos-updater:` line names the step that failed.
- **Cause, and fix, by case:**
  - *Signature or digest mismatch:* the host's public key does not match
    the deploy machine's private key. Reinstall the public key
    ([one-time setup](macos_worker_updates.md#one-time-setup)).
  - *`bundle install` or `npm ci` failed:* read the gem or package error. A
    gem whose precompiled darwin build does not fit the pinned Ruby must be
    built from source (see
    [precompiled native gems](../pitfalls/macos-hosts.md#precompiled-native-gems-on-a-frozen-install)).
  - *`macos-worker-check` failed:* its `FAIL` lines name the missing piece.
    See [Xcode or simulator failures](#xcode-or-simulator-failures) or the
    [env file contract](macos-worker-host.md#env-file-contract).
  - *`macos-runtime-env is missing or outdated`:* the host predates the
    pinned toolchain. Rerun [the installer](macos-worker-host.md#install).

## The updater never updates

- **Confirm:** `updater.log` shows no polls, or shows HTTP errors.
  `sudo launchctl print system/com.syrus.updater` shows its state.
- **Cause, and fix, by case:**
  - *`pinned update public key not found`:* install the key
    ([one-time setup](macos_worker_updates.md#one-time-setup)).
  - *HTTP 401 or 403:* `SYRUS_MACOS_WORKER_TOKEN` has expired or is
    missing. Issue a new one and put it in the env file.
  - *An HTTPS or connection error:* `SYRUS_APP_HOST` is wrong or
    unreachable. Check [network requirements](macos-worker-host.md#network-requirements).
  - *The updater is not loaded at all:* rerun [the installer](macos-worker-host.md#install).

## The worker does not start or keeps restarting

- **Confirm:** run `sudo launchctl print system/com.syrus.worker` (look at
  `state` and `last exit code`) and `tail /var/log/syrus/worker.err.log`.
- **Cause, and fix, by case:**
  - *`missing required env var`:* complete the
    [env file](macos-worker-host.md#env-file-contract).
  - *A pinned Ruby, Node, or bundle is missing:* the worker refuses to fall
    back to the host's copy. Rerun [the installer](macos-worker-host.md#install).
  - *Database connection errors:* `DB_HOST` is unreachable from the host's
    address, so check the LoadBalancer's source ranges. Never fall back to a
    tunnel
    ([pitfall](../pitfalls/macos-hosts.md#tunnelling-the-database-through-kubectl-port-forward)).
  - *The process is still stopping:* on SIGTERM the old worker drains for up
    to an hour. This is expected after an update.

## `macos-worker-check` fails on Homebrew, Ruby, or Node

- **Confirm:** you ran `bin/macos-worker-check` directly from a login shell.
- **Cause:** your shell's `PATH` includes Homebrew or `/usr/local`, or lacks
  the pinned toolchain.
- **Fix:** run the check through the wrapper:
  `sudo -u syrus-worker /opt/syrus/current/bin/macos-worker --check --env-file /etc/syrus/worker.env`.

## Xcode or simulator failures

- **Confirm:** the [wrapped check](#macos-worker-check-fails-on-homebrew-ruby-or-node)
  prints `FAIL` for `xcode-select`, `xcodebuild`, or the simulator runtimes.
  The worker's capability probe diagnostics in `GET /queue/workers` show the
  same.
- **Cause:** Command Line Tools are selected instead of full Xcode, the
  license has not been accepted, or no simulator runtime is installed.
- **Fix:** `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`,
  then `sudo xcodebuild -license accept`, then install the runtimes in Xcode.
  The worker advertises `runtime:ios_simulator` only once the probe passes.

## Keychain or signing failures

- **Confirm:** a Run's `xcodebuild` fails on code signing, but the same
  build works from an admin login.
- **Cause:** the `syrus-worker` launchd user cannot reach the keychain,
  certificates, or provisioning profiles.
- **Fix:** grant that user non-interactive access, and test as that user, not
  from an admin shell.

## A drain never finishes

- **Confirm:** the drain state in worker health stays `draining`.
- **Cause:** a long Run is still active, or the host went offline while
  draining.
- **Fix:** `POST /api/v1/app/admin/macos_worker_update/clear` completes the
  drain, and `.../force_terminate` restarts the host anyway
  ([drain flow](macos_worker_updates.md#drain-aware-manual-updates)). Deploys
  never create drains.

## The host rebooted and the worker never came back

- **Confirm:** the host answers ping but sends no heartbeat, and the services
  are not running.
- **Cause:** with FileVault on, a Mac waits at the pre-boot unlock screen
  after a reboot, and launchd starts nothing until someone unlocks the disk.
- **Fix:** unlock the disk at the console, or with `fdesetup authrestart` for
  a planned reboot. Afterwards, check [the health check](macos-workers.md#health-check).

## An agent CLI or `mise` is missing

- **Confirm:** a Run fails with `claude`, `codex`, or `mise` not found, or the
  check fails `require_command`.
- **Cause:** `/opt/syrus/agent-clis` or `/opt/syrus/tools` is incomplete.
- **Fix:** rerun [the installer](macos-worker-host.md#install). It reinstalls
  the pinned CLIs whenever their versions differ.

## CPU and memory pressure charts are empty

- **Cause:** this is expected. `WorkerHostHealthSampler` reads Linux `/proc`
  and cgroup files, so on macOS those fields are reported as absent. Disk,
  capabilities, version, queues, heartbeats, and drain or update state still
  report normally.

Return to the [macOS workers hub](macos-workers.md).
