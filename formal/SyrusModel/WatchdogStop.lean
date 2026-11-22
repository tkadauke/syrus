/-!
# DOC-44 desktop: watchdog recovery does not override a deliberate stop

`startWatchdog` (`desktop/electron/installer/backendLifecycle.ts`) reports only
health *transitions*, against `lastHealthy`. A deliberate `stopBackend` sets
`lastHealthy := false`, so the "stopped" page is not replaced by an outage
report. Before the fix, a tick checked `busy` only when it began and then
awaited a health probe. If a stop ran to completion while that probe was
outstanding, the stale "healthy" answer flipped `lastHealthy` back, and the
next tick reported the stopped stack as `containers-down` (F80).

After the fix, every lifecycle action bumps a generation, and a tick drops a
result whose generation changed while it was probing.

Events, over every sequence of up to seven events:

- `tickBegin` captures the generation and the actual health;
- `tickEnd` reports `observed` if it is still current and differs from
  `lastHealthy`;
- `stop` and `start` are deliberate actions;
- `crash` and `recover` are the stack changing on its own.

Proved:

- after a `stop` with no later `start` or `recover`, nothing is ever reported
  (`stop_is_never_overridden`). A stack that genuinely comes back after a stop
  is real news and is reported. The old behaviour violates this
  (`before_violates`).
- With no lifecycle action, a `crash` followed by a full tick is reported
  (`crash_is_reported`).
-/

namespace SyrusModel
namespace WatchdogStop

inductive Event where
  | tickBegin
  | tickEnd
  | stop
  | start
  | crash
  | recover
deriving DecidableEq, Repr

structure State where
  generation : Nat := 0
  lastHealthy : Bool := true
  actual : Bool := true
  pending : Option (Nat × Bool) := none
  reports : List Bool := []
deriving Repr

def step (guarded : Bool) (s : State) : Event → State
  | .tickBegin => if s.pending.isSome then s else { s with pending := some (s.generation, s.actual) }
  | .tickEnd =>
    match s.pending with
    | none => s
    | some (g, observed) =>
      let s := { s with pending := none }
      if (guarded && g != s.generation) || observed == s.lastHealthy then s
      else { s with lastHealthy := observed, reports := s.reports ++ [observed] }
  | .stop => { s with actual := false, lastHealthy := false, generation := s.generation + 1 }
  | .start => { s with actual := true, generation := s.generation + 1 }
  | .crash => { s with actual := false }
  | .recover => { s with actual := true }

def run (guarded : Bool) (events : List Event) : State := events.foldl (step guarded) {}

def allEvents : List Event := [.tickBegin, .tickEnd, .stop, .start, .crash, .recover]

def sequences : Nat → List (List Event)
  | 0 => [[]]
  | k + 1 => [] :: (sequences k).flatMap (fun rest => allEvents.map (· :: rest))

/-- After the last `stop`, with no `start` after it, no report is made. -/
def stopHolds (guarded : Bool) (events : List Event) : Bool :=
  match events.findIdx? (· == .stop) with
  | none => true
  | some _ =>
    let lastStop := events.length - 1 - (events.reverse.findIdx (· == .stop))
    let before := events.take (lastStop + 1)
    let after := events.drop (lastStop + 1)
    after.contains .start || after.contains .recover ||
      (run guarded events).reports.length == (run guarded before).reports.length

def check : Bool := (sequences 7).all (stopHolds true)

theorem stop_is_never_overridden : check = true := by native_decide

theorem before_violates :
    stopHolds false [.tickBegin, .stop, .tickEnd] = false := by native_decide

theorem crash_is_reported :
    (run true [.crash, .tickBegin, .tickEnd]).reports = [false] := by native_decide

end WatchdogStop
end SyrusModel
