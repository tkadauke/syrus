# Why ShipIt can remain submitted without starting

## Conclusion

The install location is not the cause. Electron 39.8.10 contains an older
Squirrel.Mac launcher which submits ShipIt with a vestigial `MachServices`
demand trigger. When macOS puts the user's launchd domain into
`on-demand-only` mode, launchd suppresses the job's `RunAtLoad`/`KeepAlive`
start and waits for a connection to that Mach service. Nothing in this
Squirrel version ever makes that connection, so the job can remain submitted
with zero runs indefinitely.

A downloaded but not yet installed macOS system update is a confirmed way for
the GUI domain to enter this mode. A disabled override can lead to the same
end state, although the observed job was reported as not disabled. The exact
observations here—submitted, not running, never exited, no output files, and
an immediate successful install after `launchctl kickstart`—are characteristic
of this launch-demand deadlock. They are not characteristic of an invalid
program path, signature failure, permissions failure, or a ShipIt process
killed when its parent exits.

Electron fixed this upstream after the 39.x line. The eventual fix preserved
the Mach service and explicitly sent it a lightweight XPC message after
submission, giving launchd the on-demand event it requires. Upgrading to an
Electron release containing that fix is the contained follow-up for Syrus.

## Exact submission path

Syrus calls `electron-updater` 6.8.9's `MacUpdater.quitAndInstall()`. That
class is an adapter around Electron's native `autoUpdater`, not a separate
installer. During download it starts a loopback HTTP server, points the native
updater at it, and calls `nativeUpdater.checkForUpdates()`. Electron hands the
archive to its bundled Squirrel.Mac. Once Squirrel has staged and verified the
update, `quitAndInstall()` calls the native updater's `quitAndInstall()` and
Squirrel rewrites `ShipItState.plist` to request relaunch before terminating
the app.

The relevant bundled Squirrel revision is
`0e5d146ba13101a1302d59ea6e6e0b3cace4ae38`, pinned by Electron 39.8.10's
`DEPS`. Its `SQRLShipItLauncher` does the following while preparing the
update, before the app quits:

1. Builds an in-memory launchd dictionary with `ProgramArguments` pointing to
   `Squirrel.framework/Resources/ShipIt`, stdout/stderr paths, a two-second
   throttle, `KeepAlive = { SuccessfulExit = false }`, and a `MachServices`
   entry named after the ShipIt job label.
2. Chooses the user launchd domain when the target bundle and its parent are
   writable; otherwise it obtains authorization and uses the system domain.
3. Removes an earlier job with `SMJobRemove` and submits the new dictionary
   with the deprecated ServiceManagement API `SMJobSubmit`.

There is no plist installed on disk and no `SMAppService`. This is the legacy
submitted-job mechanism. There is also no later `launchctl start` or
`kickstart`: the code expects submission plus the launchd dictionary's demand
conditions to start ShipIt. On an ordinary domain, the `KeepAlive` condition
causes the initial start and restarts abnormal exits. ShipIt then waits for the
host application to terminate before swapping bundles.

Thus the submitting app exiting is expected and safe. ShipIt is meant to have
already been spawned by launchd and, if necessary, to wait for that exit.
launchd owns the submitted job independently of the submitting process.

## Why this job does not start

The `MachServices` entry is left over from a 2013 Squirrel design in which
ShipIt was an XPC service. ShipIt is no longer an XPC service, and neither
Squirrel nor Electron connects to the advertised port in the pinned version.
Under normal launchd operation the `KeepAlive.SuccessfulExit = false`
condition starts ShipIt anyway. In an on-demand-only GUI domain, launchd
suppresses that automatic start, sees the Mach service as the available demand
trigger, and waits forever for a message that cannot arrive.

Upstream reproduced the resulting state as:

```text
state = not running
runs = 0
pended nondemand spawn = semaphore
last exit code = (never exited)
semaphores = {
    successful exit => 0
}
```

The corresponding launchd log says that the spawn is pending because the
domain is in on-demand-only mode. A pending macOS system update was confirmed
upstream to put the GUI domain into this mode. Electron 40.9.3+, 41.4.0+, and
42.0.0+ contain the fix; Electron 39.8.10 does not.

### Candidate assessment

- **Pending macOS system update / on-demand-only GUI domain:** strongly
  consistent and the leading cause. It produces the exact zero-run state,
  deterministic recurrence, absent ShipIt logs, and successful kickstart.
- **Persisted launchd disabled override:** produces a closely related failure,
  but is ruled out for this observation by the reported `not disabled` state.
  Re-enabling a previously disabled job can also leave the demand semaphore
  pended, so `print-disabled` remains worth recording in the confirmation.
- **The submitting app exits before launchd spawns ShipIt:** ruled out as an
  independent cause. The job is submitted while the update is prepared, not
  by an exit hook, and launchd jobs outlive their submitter. The application
  must exit before ShipIt can replace it.
- **ShipIt executable under the user's home directory:** inconsistent with
  the evidence. `SMJobSubmit` accepted the dictionary, and `kickstart` executed
  that exact registered program successfully. A path policy, quarantine,
  ownership, executable-bit, or code-signing rejection would also affect the
  explicit start and normally yield an attempted run or launchd error.
- **Target bundle permissions or elevation:** inconsistent. A writable user
  install deliberately selects `kSMDomainUserLaunchd`; a non-writable target
  selects the authorized system-domain path. Either kind of failure occurs
  before successful submission or after ShipIt starts, not at `runs = 0`.
- **Bad staged archive, signature, state file, swap, or relaunch:** ruled out by
  the successful kickstart using the same job and state.
- **Throttle/backoff or repeated crashes:** ruled out by `last exit code =
  (never exited)` and the absence of output files.
- **Background-activity termination after app exit:** a real concern on newer
  macOS versions, but it kills an already running ShipIt. It cannot explain
  zero runs and no log-file creation.

## Effect of `~/Applications`

`desktop/electron/selfInstall.ts` intentionally treats `/Applications` and
the current user's `Applications` directory as installed locations. It picks
the system directory only when that directory or an existing system copy is
writable; otherwise it creates or replaces the user copy. Once running,
Squirrel derives the target from `NSRunningApplication.currentApplication`
rather than assuming `/Applications`.

For a user-owned bundle and user-owned parent directory, Squirrel chooses the
unprivileged user launchd domain. Its ShipIt request records the actual bundle
URL and its installer operates on that URL. There is no `/Applications`
constant in this update path.

The location can therefore change whether Squirrel chooses the user or system
launchd domain, but it does not make user-local installs intrinsically
unupdatable. In this incident the user-domain choice exposes the app to the
GUI domain's on-demand-only state; the home-directory program path itself is
not rejected. Prior successful creation of the same app's ShipIt cache is also
consistent with the domain usually operating normally.

## One confirming check

On a staged-but-stuck update, before kickstarting it, substitute the real
bundle identifier and run:

```sh
label="<bundle-id>.ShipIt"
launchctl print "gui/$(id -u)/$label"
launchctl print-disabled "gui/$(id -u)" | grep -F "$label"
log show --last 15m --info --style compact \
  --predicate 'process == "launchd" AND eventMessage CONTAINS[c] "pending spawn, domain in on-demand-only mode"'
```

The cause is confirmed if the job reports zero runs plus `pended nondemand
spawn = semaphore`/`successful exit => 0`, the disabled listing is absent or
false, and the launchd log names that ShipIt job as pending because the domain
is in on-demand-only mode. A subsequent `launchctl kickstart -p` succeeding is
the already-observed control showing that only the automatic demand gate was
blocked.

## Follow-up scope

Upgrade the desktop Electron dependency from 39.8.10 to a supported release
which includes the upstream ShipIt XPC-trigger fix, rebuild the lockfile, and
exercise the existing desktop packaging and auto-update checks. The important
acceptance test is a signed packaged update on macOS while the GUI launchd
domain is in on-demand-only mode: ShipIt must acquire a PID without manual
kickstart, apply the staged update, and relaunch the app. This is preferable to
a Syrus-only `launchctl` workaround because ShipIt and the submission logic
are compiled into Electron's Squirrel framework.

## Sources

- Electron 39.8.10 `DEPS`, which pins Squirrel.Mac:
  <https://github.com/electron/electron/blob/v39.8.10/DEPS>
- Pinned Squirrel launcher implementation:
  <https://github.com/Squirrel/Squirrel.Mac/blob/0e5d146ba13101a1302d59ea6e6e0b3cace4ae38/Squirrel/SQRLShipItLauncher.m>
- Pinned Squirrel updater lifecycle:
  <https://github.com/Squirrel/Squirrel.Mac/blob/0e5d146ba13101a1302d59ea6e6e0b3cace4ae38/Squirrel/SQRLUpdater.m>
- electron-updater 6.8.9 `MacUpdater`:
  <https://github.com/electron-userland/electron-builder/blob/electron-updater%406.8.9/packages/electron-updater/src/MacUpdater.ts>
- Electron's upstream diagnosis and real-world confirmation:
  <https://github.com/electron/electron/issues/50866>
- Electron's final XPC-trigger fix:
  <https://github.com/electron/electron/pull/51191>
- The corresponding Squirrel.Mac upstream work:
  <https://github.com/Squirrel/Squirrel.Mac/pull/312>
