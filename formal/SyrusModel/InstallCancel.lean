/-!
# DOC-44 desktop: a cancelled install never spawns an installer

"Cancellation eventually terminates the complete child-process tree", "Every
terminal path releases the lock", and "No failure path reports done", for the
onboarding installer (`OnboardingDriver.performStartInstall`).

Starting an install awaits, in order: the state directory, the backend
manifest, and the install lock. Then it spawns the installer. A Cancel can
arrive at any of these await points. Before the spawn, `cancelInstall` resets
the wizard to Welcome and lets the start run out. After the spawn, it kills
the process tree, and `handleExit` returns to Welcome.

Before F83, cancellation was checked only after the manifest read. A cancel
during lock acquisition was missed: the start went on to "installing" and
spawned an installer that nobody killed. The start now checks again after the
lock, and releases the lock when it does stop.

For a cancel at each point (or never):

- `cancelled_start_never_spawns`: a cancel before the spawn means no installer
  is spawned and the lock is not held;
- `cancel_after_spawn_kills`: a cancel after the spawn kills the installer;
- in every cancelled case the wizard ends at Welcome and never reports done.

The old behaviour spawns on a cancel during lock acquisition
(`before_violates`).
-/

namespace SyrusModel
namespace InstallCancel

/-- Where the cancel lands: before the step at this index, or never. -/
inductive Point where
  | duringMkdir
  | duringManifest
  | duringLock
  | afterSpawn
  | never
deriving DecidableEq, Repr

structure Outcome where
  spawned : Bool
  killed : Bool
  lockHeld : Bool
  phase : String
deriving DecidableEq, Repr

/-- `checkAfterLock` is the F83 fix. -/
def start (checkAfterLock : Bool) (p : Point) : Outcome :=
  -- Cancel during mkdir or manifest is seen by the check after the manifest.
  if p == .duringMkdir || p == .duringManifest then
    { spawned := false, killed := false, lockHeld := false, phase := "welcome" }
  else if p == .duringLock && checkAfterLock then
    { spawned := false, killed := false, lockHeld := false, phase := "welcome" }
  else if p == .duringLock then
    -- Missed: installing, spawned, never killed; the lock is held until it exits.
    { spawned := true, killed := false, lockHeld := true, phase := "local.installing" }
  else if p == .afterSpawn then
    -- killInstallChild, then handleExit sees cancelRequested; the supervisor releases the lock.
    { spawned := true, killed := true, lockHeld := false, phase := "welcome" }
  else
    { spawned := true, killed := false, lockHeld := false, phase := "done" }

def cancelled : List Point := [.duringMkdir, .duringManifest, .duringLock, .afterSpawn]

def check : Bool :=
  cancelled.all (fun p =>
    let o := start true p
    o.phase == "welcome" && !o.lockHeld && (o.spawned == o.killed))

theorem cancelled_start_never_spawns_and_cancel_after_spawn_kills : check = true := by native_decide

theorem before_violates : (start false .duringLock).spawned && !(start false .duringLock).killed = true := by
  native_decide

end InstallCancel
end SyrusModel
